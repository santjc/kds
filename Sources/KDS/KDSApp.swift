import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
  func applicationDidFinishLaunching(_ notification: Notification) {
    NSApp.setActivationPolicy(.accessory)
  }
}

@main
struct KDSApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
  @StateObject private var store = PortStore.live()
  @StateObject private var launchAtLogin = LaunchAtLoginController()

  var body: some Scene {
    MenuBarExtra("Kill Dev Servers", systemImage: "server.rack") {
      KDSMenuView()
        .environmentObject(store)
        .environmentObject(launchAtLogin)
    }
    .menuBarExtraStyle(.window)
  }
}
