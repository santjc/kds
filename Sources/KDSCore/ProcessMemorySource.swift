import Foundation

/// A running process and how much memory it is holding.
///
/// `residentBytes` is RSS as reported by `ps`. RSS counts shared framework pages against
/// every process that maps them, so totals read slightly higher than Activity Monitor's
/// phys_footprint column. It is the right order of magnitude for spotting hogs.
public struct MemoryProcess: Identifiable, Sendable, Hashable {
  public let pid: Int32
  public let processName: String
  public let commandPath: String
  public let residentBytes: UInt64
  public let cpuPercent: Double
  public let ownerUID: UInt32

  public var id: Int32 { pid }

  public init(
    pid: Int32,
    processName: String,
    commandPath: String,
    residentBytes: UInt64,
    cpuPercent: Double,
    ownerUID: UInt32
  ) {
    self.pid = pid
    self.processName = processName
    self.commandPath = commandPath
    self.residentBytes = residentBytes
    self.cpuPercent = cpuPercent
    self.ownerUID = ownerUID
  }
}

public protocol ProcessMemorySource: Sendable {
  func snapshot() async throws -> [MemoryProcess]
}

public struct PSProcessMemorySource: ProcessMemorySource {
  private let runner: any CommandRunning
  private let currentUID: UInt32

  public init(runner: any CommandRunning = SystemCommandRunner(), currentUID: UInt32 = getuid()) {
    self.runner = runner
    self.currentUID = currentUID
  }

  public func snapshot() async throws -> [MemoryProcess] {
    let result = try await runner.run(
      executable: "/bin/ps",
      arguments: ["-axo", "pid=,uid=,%cpu=,rss=,comm="],
      timeout: 2
    )

    guard result.exitCode == 0 else {
      throw ProcessMemorySourceError.failed(result.exitCode)
    }
    guard let output = String(data: result.output, encoding: .utf8) else {
      throw CommandRunnerError.unreadableOutput
    }

    return PSProcessParser.parse(output, currentUID: currentUID)
  }
}

public enum ProcessMemorySourceError: Error, LocalizedError {
  case failed(Int32)

  public var errorDescription: String? {
    switch self {
    case .failed(let code): "Memory scan failed with exit code \(code)"
    }
  }
}

public enum PSProcessParser {
  /// Parses `ps -axo pid=,uid=,%cpu=,rss=,comm=` output, keeping only the current user's
  /// processes, sorted by resident size descending.
  public static func parse(_ output: String, currentUID: UInt32) -> [MemoryProcess] {
    var processes: [MemoryProcess] = []

    for rawLine in output.split(whereSeparator: \.isNewline) {
      // `comm` is last and may contain spaces and slashes, so split only the four
      // leading numeric columns and keep the remainder intact.
      let fields = rawLine.split(
        maxSplits: 4, omittingEmptySubsequences: true, whereSeparator: \.isWhitespace)
      guard fields.count == 5,
        let pid = Int32(fields[0]),
        let uid = UInt32(fields[1]),
        let cpu = Double(fields[2]),
        let residentKiB = UInt64(fields[3])
      else { continue }

      guard pid > 0, uid == currentUID else { continue }

      let path = String(fields[4]).trimmingCharacters(in: .whitespaces)
      guard !path.isEmpty else { continue }

      processes.append(
        MemoryProcess(
          pid: pid,
          processName: processName(fromPath: path),
          commandPath: path,
          residentBytes: residentKiB * 1024,
          cpuPercent: cpu,
          ownerUID: uid
        ))
    }

    return processes.sorted {
      if $0.residentBytes != $1.residentBytes { return $0.residentBytes > $1.residentBytes }
      return $0.pid < $1.pid
    }
  }

  /// The display name for a `comm` value, which is usually a full executable path.
  public static func processName(fromPath path: String) -> String {
    let component = path.hasPrefix("/") ? URL(fileURLWithPath: path).lastPathComponent : path
    return component.isEmpty ? path : component
  }
}
