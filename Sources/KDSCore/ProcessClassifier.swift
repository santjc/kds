import Foundation

public enum ProcessOverride: String, Codable, Sendable {
  case include
  case protect
}

public struct ProcessClassifier: Sendable {
  private static let developmentRuntimes: Set<String> = [
    "node", "bun", "deno", "python", "python3", "ruby", "php", "java",
    "dotnet", "go", "cargo", "air", "uvicorn", "gunicorn", "puma",
    "rails", "vite", "next", "webpack", "tsx", "ts-node",
  ]

  private static let services: Set<String> = [
    "postgres", "redis-server", "mongod", "mysqld", "mariadbd", "docker",
  ]

  private let currentUID: UInt32
  private let ownPID: Int32

  public init(currentUID: UInt32 = getuid(), ownPID: Int32 = getpid()) {
    self.currentUID = currentUID
    self.ownPID = ownPID
  }

  public func classify(
    endpoint: ListeningEndpoint,
    details: ProcessDetails,
    override: ProcessOverride?
  ) -> ProcessClassification {
    if endpoint.pid == ownPID {
      return ProcessClassification(category: .protected, reason: "KDS")
    }
    if endpoint.ownerUID != currentUID {
      return ProcessClassification(category: .protected, reason: "Different user")
    }

    if let path = details.executablePath,
      path.hasPrefix("/System/") || path.hasPrefix("/usr/libexec/")
        || path.contains(".app/Contents/")
    {
      return ProcessClassification(category: .protected, reason: "macOS or GUI app")
    }
    if override == .protect {
      return ProcessClassification(category: .protected, reason: "Protected by you")
    }
    if override == .include {
      return ProcessClassification(category: .development, reason: "Included by you")
    }

    let process = normalizedProcessName(
      endpoint.processName, executablePath: details.executablePath)
    if Self.services.contains(process) {
      return ProcessClassification(category: .other, reason: "Local service")
    }
    if details.projectRoot != nil {
      return ProcessClassification(category: .development, reason: "Project directory")
    }
    if Self.developmentRuntimes.contains(process) || process.hasPrefix("python") {
      return ProcessClassification(category: .development, reason: "Development runtime")
    }

    return ProcessClassification(category: .other, reason: "Unrecognized listener")
  }

  private func normalizedProcessName(_ name: String, executablePath: String?) -> String {
    let pathName = executablePath.map { URL(fileURLWithPath: $0).lastPathComponent }
    return (pathName ?? name).lowercased()
  }
}
