import AppKit
import SwiftUI

struct KDSMenuView: View {
  @EnvironmentObject private var store: PortStore
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
    }
    .onDisappear {
      usageStore.stop()
      store.stopVisibleScanning()
    }
  }

  private var header: some View {
    HStack(spacing: 8) {
      Text("KDS")
        .font(.headline)
      Text("\(store.developmentEndpoints.count) dev")
        .font(.caption)
        .foregroundStyle(.secondary)
      Spacer()
    }
    .padding(.horizontal, MenuMetrics.horizontalPadding)
    .frame(height: 38)
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

      ServerFooterActions()
    }
    .padding(.horizontal, MenuMetrics.horizontalPadding)
    .frame(height: 44)
  }
}
