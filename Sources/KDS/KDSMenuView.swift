import AppKit
import SwiftUI

enum MenuTab: String, CaseIterable, Identifiable {
  case servers
  case memory

  var id: String { rawValue }

  var title: String {
    switch self {
    case .servers: "Servers"
    case .memory: "Memory"
    }
  }
}

struct KDSMenuView: View {
  @EnvironmentObject private var store: PortStore
  @EnvironmentObject private var memoryStore: MemoryStore
  @EnvironmentObject private var usageStore: SystemUsageStore
  @EnvironmentObject private var launchAtLogin: LaunchAtLoginController
  @AppStorage("selectedTab") private var tab: MenuTab = .servers

  var body: some View {
    // No fixed height: the panel is as short as its content allows and only the
    // scrollable region grows, up to MenuMetrics.maxContentHeight.
    VStack(spacing: 0) {
      header
      UsageGaugesView()
      TabBar(selection: $tab)

      switch tab {
      case .servers: ServersTabView()
      case .memory: MemoryTabView()
      }

      Divider()
      footer
    }
    .frame(width: MenuMetrics.width)
    .fixedSize(horizontal: false, vertical: true)
    .onAppear {
      launchAtLogin.refreshStatus()
      usageStore.start()
      startScanning(for: tab)
    }
    .onDisappear {
      usageStore.stop()
      store.stopVisibleScanning()
      memoryStore.stopVisibleScanning()
    }
    .onChange(of: tab) { newTab in
      // Only one poller runs at a time, so lsof and ps never overlap.
      store.stopVisibleScanning()
      memoryStore.stopVisibleScanning()
      startScanning(for: newTab)
    }
  }

  private func startScanning(for tab: MenuTab) {
    switch tab {
    case .servers: store.startVisibleScanning()
    case .memory: memoryStore.startVisibleScanning()
    }
  }

  private var header: some View {
    HStack(spacing: 8) {
      Text("KDS")
        .font(.headline)
      Text(headerSubtitle)
        .font(.caption)
        .foregroundStyle(.secondary)
      Spacer()
    }
    .padding(.horizontal, MenuMetrics.horizontalPadding)
    .frame(height: 38)
  }

  private var headerSubtitle: String {
    switch tab {
    case .servers: "\(store.developmentEndpoints.count) dev"
    case .memory: "\(memoryStore.processes.count) processes"
    }
  }

  private var footer: some View {
    HStack {
      Menu {
        Toggle(
          "Launch at Login",
          isOn: Binding(
            get: { launchAtLogin.isEnabled },
            set: { launchAtLogin.setEnabled($0) }
          )
        )
        Divider()
        Button("Quit KDS") { NSApp.terminate(nil) }
      } label: {
        IconControlLabel(systemName: "gearshape", title: "Settings")
      }
      .menuStyle(.borderlessButton)
      .menuIndicator(.hidden)
      .fixedSize()
      .help("Settings")
      .interactiveIconControl()

      Spacer()

      switch tab {
      case .servers: ServersFooterActions()
      case .memory: MemoryFooterSummary()
      }
    }
    .padding(.horizontal, MenuMetrics.horizontalPadding)
    .frame(height: 44)
  }
}
