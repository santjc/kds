import SwiftUI

struct KDSMenuView: View {
  @EnvironmentObject private var store: PortStore
  @EnvironmentObject private var background: BackgroundStore
  @EnvironmentObject private var usageStore: SystemUsageStore
  @EnvironmentObject private var launchAtLogin: LaunchAtLoginController

  var body: some View {
    // No fixed height: the panel is as short as its content allows and only the
    // scrollable region grows, up to MenuMetrics.maxContentHeight.
    VStack(spacing: 0) {
      header
      UsageGaugesView()
      ServerTableView()
      Divider()
      footer
    }
    .frame(width: MenuMetrics.width)
    .fixedSize(horizontal: false, vertical: true)
    .onAppear {
      launchAtLogin.refreshStatus()
      usageStore.start()
      store.startVisibleScanning()
      background.startVisibleScanning()
    }
    .onDisappear {
      usageStore.stop()
      store.stopVisibleScanning()
      background.stopVisibleScanning()
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
    let servers = "\(store.developmentEndpoints.count) dev"
    guard !background.processes.isEmpty else { return servers }
    return "\(servers) · \(background.processes.count) background"
  }

  private var footer: some View {
    HStack {
      Spacer()
      ServerFooterActions()
    }
    .padding(.horizontal, MenuMetrics.horizontalPadding)
    .frame(height: 44)
  }
}
