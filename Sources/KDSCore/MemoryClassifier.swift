import Foundation

/// Decides which processes on the Memory tab are safe to terminate.
///
/// The rules mirror `ProcessClassifier` with one deliberate difference: processes inside
/// an `.app` bundle are `.other` rather than `.protected`. On the ports tab a GUI app is
/// never the thing you meant to kill; on the memory tab a multi-gigabyte browser usually is.
/// `.other` still requires a confirmation dialog in the UI.
public struct MemoryClassifier: Sendable {
  /// Terminating any of these leaves the session unusable.
  public static let criticalProcesses: Set<String> = [
    "launchd", "windowserver", "loginwindow", "finder", "dock", "systemuiserver",
    "coreaudiod", "kernel_task", "logind", "securityd",
  ]

  private static let systemPathPrefixes = [
    "/System/", "/usr/libexec/", "/usr/sbin/", "/sbin/", "/usr/bin/", "/Library/Apple/",
  ]

  private let currentUID: UInt32
  private let ownPID: Int32

  public init(currentUID: UInt32 = getuid(), ownPID: Int32 = getpid()) {
    self.currentUID = currentUID
    self.ownPID = ownPID
  }

  public func classify(
    process: MemoryProcess,
    override: ProcessOverride?
  ) -> ProcessClassification {
    if process.pid == ownPID {
      return ProcessClassification(category: .protected, reason: "KDS")
    }
    if process.ownerUID != currentUID {
      return ProcessClassification(category: .protected, reason: "Different user")
    }

    let name = process.processName.lowercased()
    if Self.criticalProcesses.contains(name) {
      return ProcessClassification(category: .protected, reason: "Critical system process")
    }
    if Self.systemPathPrefixes.contains(where: { process.commandPath.hasPrefix($0) }) {
      return ProcessClassification(category: .protected, reason: "macOS system process")
    }

    if override == .protect {
      return ProcessClassification(category: .protected, reason: "Protected by you")
    }
    if override == .include {
      return ProcessClassification(category: .development, reason: "Included by you")
    }

    if ProcessClassifier.services.contains(name) {
      return ProcessClassification(category: .other, reason: "Local service")
    }
    if ProcessClassifier.developmentRuntimes.contains(name) || name.hasPrefix("python") {
      return ProcessClassification(category: .development, reason: "Development runtime")
    }
    if process.commandPath.contains(".app/Contents/") {
      return ProcessClassification(category: .other, reason: "App")
    }

    return ProcessClassification(category: .other, reason: "Background process")
  }
}

/// A `MemoryProcess` paired with its classification, ready for display.
public struct DisplayMemoryProcess: Identifiable, Sendable, Hashable {
  public let process: MemoryProcess
  public let classification: ProcessClassification

  public var id: Int32 { process.pid }

  public init(process: MemoryProcess, classification: ProcessClassification) {
    self.process = process
    self.classification = classification
  }
}
