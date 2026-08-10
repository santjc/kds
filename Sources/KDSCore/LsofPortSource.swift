import Foundation

public protocol PortSource: Sendable {
  func snapshot() async throws -> [ListeningEndpoint]
}

public struct LsofPortSource: PortSource {
  private let runner: any CommandRunning
  private let currentUID: UInt32

  public init(runner: any CommandRunning = SystemCommandRunner(), currentUID: UInt32 = getuid()) {
    self.runner = runner
    self.currentUID = currentUID
  }

  public func snapshot() async throws -> [ListeningEndpoint] {
    let result = try await runner.run(
      executable: "/usr/sbin/lsof",
      arguments: ["-nP", "+c0", "-iTCP", "-sTCP:LISTEN", "-FpcuLn"],
      timeout: 2
    )

    guard result.exitCode == 0 || result.exitCode == 1 else {
      throw LsofPortSourceError.failed(result.exitCode)
    }
    guard let output = String(data: result.output, encoding: .utf8) else {
      throw CommandRunnerError.unreadableOutput
    }

    return LsofParser.parse(output, currentUID: currentUID)
  }
}

public enum LsofPortSourceError: Error, LocalizedError {
  case failed(Int32)

  public var errorDescription: String? {
    switch self {
    case .failed(let code): "Port scan failed with exit code \(code)"
    }
  }
}

public enum LsofParser {
  public static func parse(_ output: String, currentUID: UInt32) -> [ListeningEndpoint] {
    var records: [Record] = []
    var current: Record?

    for rawLine in output.split(whereSeparator: \.isNewline) {
      guard let field = rawLine.first else { continue }
      let value = String(rawLine.dropFirst())

      if field == "p" {
        if let current { records.append(current) }
        current = Record(pid: Int32(value) ?? -1)
        continue
      }

      guard current != nil else { continue }
      switch field {
      case "c": current?.command = value
      case "u": current?.uid = UInt32(value)
      case "L": current?.userName = value
      case "n": current?.names.append(value)
      default: break
      }
    }
    if let current { records.append(current) }

    var merged: [String: ListeningEndpoint] = [:]
    for record in records where record.pid > 0 && record.uid == currentUID {
      for name in record.names {
        guard let parsed = parseAddress(name) else { continue }
        let key = "\(record.pid):\(parsed.port)"
        let address = parsed.host.isEmpty ? "*" : parsed.host

        if let existing = merged[key] {
          merged[key] = ListeningEndpoint(
            port: existing.port,
            pid: existing.pid,
            ownerUID: existing.ownerUID,
            userName: existing.userName,
            processName: existing.processName,
            addresses: existing.addresses.union([address])
          )
        } else {
          merged[key] = ListeningEndpoint(
            port: parsed.port,
            pid: record.pid,
            ownerUID: currentUID,
            userName: record.userName,
            processName: record.command ?? "PID \(record.pid)",
            addresses: [address]
          )
        }
      }
    }

    return merged.values.sorted {
      if $0.port != $1.port { return $0.port < $1.port }
      return $0.pid < $1.pid
    }
  }

  private static func parseAddress(_ value: String) -> (host: String, port: UInt16)? {
    let local = value.components(separatedBy: "->").first ?? value
    guard let separator = local.lastIndex(of: ":"),
      let port = UInt16(local[local.index(after: separator)...])
    else {
      return nil
    }

    var host = String(local[..<separator])
    if host.hasPrefix("[") && host.hasSuffix("]") {
      host.removeFirst()
      host.removeLast()
    }
    return (host, port)
  }

  private struct Record {
    let pid: Int32
    var command: String?
    var uid: UInt32?
    var userName: String?
    var names: [String] = []
  }
}
