import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
  private var statusItem: StatusItemController?

  func applicationDidFinishLaunching(_ notification: Notification) {
    NSApp.setActivationPolicy(.accessory)
    statusItem = StatusItemController()
  }
}

@main
struct KDSApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

  // The menu bar item is AppKit (`StatusItemController`): SwiftUI's MenuBarExtra has no
  // right-click. An app still needs one scene, and an empty Settings scene shows nothing.
  var body: some Scene {
    Settings { EmptyView() }
  }
}
