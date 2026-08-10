import Darwin
import Foundation

public protocol ProcessInspecting: Sendable {
  func inspect(pid: Int32) async -> ProcessDetails
}

public struct SystemProcessInspector: ProcessInspecting {
  private let runner: any CommandRunning
  private let projectResolver: ProjectResolver

  public init(
    runner: any CommandRunning = SystemCommandRunner(),
    projectResolver: ProjectResolver = ProjectResolver()
  ) {
    self.runner = runner
    self.projectResolver = projectResolver
  }

  public func inspect(pid: Int32) async -> ProcessDetails {
    async let executablePath = Self.executablePath(pid: pid)
    async let workingDirectory = workingDirectory(pid: pid)
    let (path, cwd) = await (executablePath, workingDirectory)

    return ProcessDetails(
      executablePath: path,
      workingDirectory: cwd,
      projectRoot: cwd.flatMap(projectResolver.projectRoot(startingAt:))
    )
  }

  private static func executablePath(pid: Int32) -> String? {
    var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
    let count = buffer.withUnsafeMutableBytes { bytes in
      proc_pidpath(pid, bytes.baseAddress, UInt32(bytes.count))
    }
    guard count > 0 else { return nil }
    let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
    return String(decoding: bytes, as: UTF8.self)
  }

  private func workingDirectory(pid: Int32) async -> String? {
    guard
      let result = try? await runner.run(
        executable: "/usr/sbin/lsof",
        arguments: ["-a", "-p", String(pid), "-d", "cwd", "-Fn"],
        timeout: 1
      ), result.exitCode == 0,
      let output = String(data: result.output, encoding: .utf8)
    else {
      return nil
    }

    return
      output
      .split(whereSeparator: \.isNewline)
      .first(where: { $0.first == "n" })
      .map { String($0.dropFirst()) }
  }
}

public struct ProjectResolver: Sendable {
  private static let markers = [
    ".git", "Package.swift", "package.json", "pyproject.toml", "Cargo.toml",
    "go.mod", "Gemfile", "composer.json",
  ]

  public init() {}

  public func projectRoot(startingAt path: String) -> String? {
    let manager = FileManager.default
    var directory = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL

    while directory.path != "/" {
      if Self.markers.contains(where: {
        manager.fileExists(atPath: directory.appendingPathComponent($0).path)
      }) {
        return directory.path
      }
      directory.deleteLastPathComponent()
    }

    return nil
  }
}
