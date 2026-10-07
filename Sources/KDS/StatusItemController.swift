import AppKit
import Combine
import SwiftUI

/// The menu bar item. Left click toggles the panel; right click (or control-click) opens
/// the app menu, which is where Launch at Login and Quit live.
@MainActor
final class StatusItemController: NSObject {
  private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
  private let store = PortStore.live()
  private let background = BackgroundStore.live()
  private let usageStore = SystemUsageStore()
  private let launchAtLogin = LaunchAtLoginController()
  private let mascot = MascotAnimator()

  private var panel: MenuPanel?
  private var imageSubscription: AnyCancellable?
  private var outsideClickMonitor: Any?
  private var escapeMonitor: Any?

  override init() {
    super.init()
    guard let button = statusItem.button else { return }
    button.image = mascot.image
    button.setAccessibilityLabel("Kill Dev Servers")
    button.target = self
    button.action = #selector(handleClick)
    button.sendAction(on: [.leftMouseUp, .rightMouseUp])
    imageSubscription = mascot.$image.sink { [weak button] image in button?.image = image }
  }

  @objc private func handleClick() {
    let event = NSApp.currentEvent
    if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
      closePanel()
      showAppMenu()
    } else if panel == nil {
      openPanel()
    } else {
      closePanel()
    }
  }

  // MARK: - App menu

  private func showAppMenu() {
    launchAtLogin.refreshStatus()
    let menu = NSMenu()

    let launch = NSMenuItem(
      title: "Launch at Login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
    launch.target = self
    launch.state = launchAtLogin.isEnabled ? .on : .off
    menu.addItem(launch)

    menu.addItem(.separator())
    menu.addItem(
      NSMenuItem(title: "Quit KDS", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

    // Assigning a menu makes the click show it; clearing it afterwards gives left click
    // back to the panel.
    statusItem.menu = menu
    statusItem.button?.performClick(nil)
    statusItem.menu = nil
  }

  @objc private func toggleLaunchAtLogin() {
    launchAtLogin.setEnabled(!launchAtLogin.isEnabled)
  }

  // MARK: - Panel

  private func openPanel() {
    guard let button = statusItem.button, let buttonWindow = button.window else { return }

    let panel = MenuPanel()
    let host = SizeReportingHostingView(
      rootView: KDSMenuView()
        .environmentObject(store)
        .environmentObject(background)
        .environmentObject(usageStore)
        .environmentObject(launchAtLogin)
    )
    let anchor = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
    host.onSizeChange = { [weak panel] size in panel?.place(size: size, below: anchor) }
    panel.setContent(host)
    panel.place(size: host.fittingSize, below: anchor)
    panel.makeKeyAndOrderFront(nil)
    self.panel = panel
    button.highlight(true)

    outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(
      matching: [.leftMouseDown, .rightMouseDown]
    ) { [weak self] _ in
      MainActor.assumeIsolated { self?.closePanel() }
    }
    escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
      // Escape closes the panel, but leaves an open confirmation sheet to handle it first.
      guard event.keyCode == 53, let panel = self?.panel, panel.attachedSheet == nil else {
        return event
      }
      self?.closePanel()
      return nil
    }
  }

  /// Tearing the hosting view down, rather than hiding it, fires the SwiftUI
  /// `onDisappear` that stops every scan loop.
  private func closePanel() {
    guard let panel else { return }
    panel.orderOut(nil)
    panel.contentView = nil
    self.panel = nil
    statusItem.button?.highlight(false)
    if let outsideClickMonitor { NSEvent.removeMonitor(outsideClickMonitor) }
    if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor) }
    outsideClickMonitor = nil
    escapeMonitor = nil
  }
}

/// A borderless, non-activating panel with the menu material, like a menu bar window.
private final class MenuPanel: NSPanel {
  private static let cornerRadius: CGFloat = 10
  /// Gap between the menu bar and the panel's top edge.
  private static let gap: CGFloat = 4

  init() {
    super.init(
      contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered,
      defer: true)
    isFloatingPanel = true
    level = .statusBar
    backgroundColor = .clear
    isOpaque = false
    hasShadow = true
    hidesOnDeactivate = false
    isMovable = false
    collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
  }

  // Buttons, menus and confirmation sheets need a key window.
  override var canBecomeKey: Bool { true }

  func setContent(_ view: NSView) {
    let material = NSVisualEffectView()
    material.material = .popover
    material.blendingMode = .behindWindow
    material.state = .active
    material.wantsLayer = true
    material.layer?.cornerRadius = Self.cornerRadius
    material.layer?.masksToBounds = true

    view.translatesAutoresizingMaskIntoConstraints = false
    material.addSubview(view)
    NSLayoutConstraint.activate([
      view.leadingAnchor.constraint(equalTo: material.leadingAnchor),
      view.trailingAnchor.constraint(equalTo: material.trailingAnchor),
      view.topAnchor.constraint(equalTo: material.topAnchor),
      view.bottomAnchor.constraint(equalTo: material.bottomAnchor),
    ])
    contentView = material
  }

  /// Hangs the panel from the menu bar under `anchor`, kept on screen. The top edge
  /// stays put as the content grows or shrinks, the way a menu does.
  func place(size: NSSize, below anchor: NSRect) {
    let screen = NSScreen.screens.first { $0.frame.contains(anchor.origin) } ?? NSScreen.main
    let bounds = screen?.visibleFrame ?? .zero
    let x = min(max(anchor.midX - size.width / 2, bounds.minX + 8), bounds.maxX - size.width - 8)
    let top = anchor.minY - Self.gap
    setFrame(NSRect(x: x, y: top - size.height, width: size.width, height: size.height), display: true)
    invalidateShadow()
  }
}

/// Reports its SwiftUI content's new size whenever that size changes, so the panel can
/// follow expanding and collapsing sections.
private final class SizeReportingHostingView<Content: View>: NSHostingView<Content> {
  var onSizeChange: ((NSSize) -> Void)?

  override func invalidateIntrinsicContentSize() {
    super.invalidateIntrinsicContentSize()
    // The new size is only measurable after this layout pass.
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      self.onSizeChange?(self.fittingSize)
    }
  }
}
