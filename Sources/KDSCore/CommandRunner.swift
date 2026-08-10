import Darwin
import Foundation

public struct CommandResult: Sendable {
  public let output: Data
  public let exitCode: Int32

  public init(output: Data, exitCode: Int32) {
    self.output = output
    self.exitCode = exitCode
  }
}

public enum CommandRunnerError: Error, LocalizedError {
  case timedOut(String)
  case unreadableOutput

  public var errorDescription: String? {
    switch self {
    case .timedOut(let command): "\(command) timed out"
    case .unreadableOutput: "The command returned unreadable output"
    }
  }
}

public protocol CommandRunning: Sendable {
  func run(executable: String, arguments: [String], timeout: TimeInterval) async throws
    -> CommandResult
}

public actor SystemCommandRunner: CommandRunning {
  public init() {}

  public func run(
    executable: String,
    arguments: [String],
    timeout: TimeInterval
  ) async throws -> CommandResult {
    try await Task.detached(priority: .utility) {
      try Self.runSynchronously(executable: executable, arguments: arguments, timeout: timeout)
    }.value
  }

  private static func runSynchronously(
    executable: String,
    arguments: [String],
    timeout: TimeInterval
  ) throws -> CommandResult {
    let process = Process()
    let outputPipe = Pipe()
    let timeoutState = TimeoutState()

    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    process.standardOutput = outputPipe
    process.standardError = FileHandle.nullDevice

    try process.run()

    let timeoutWork = DispatchWorkItem {
      guard process.isRunning else { return }
      timeoutState.markTimedOut()
      process.terminate()
      usleep(250_000)
      if process.isRunning {
        Darwin.kill(process.processIdentifier, SIGKILL)
      }
    }
    DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: timeoutWork)

    let output = outputPipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    timeoutWork.cancel()

    if timeoutState.didTimeOut {
      throw CommandRunnerError.timedOut(executable)
    }

    return CommandResult(output: output, exitCode: process.terminationStatus)
  }
}

private final class TimeoutState: @unchecked Sendable {
  private let lock = NSLock()
  private var value = false

  var didTimeOut: Bool {
    lock.withLock { value }
  }

  func markTimedOut() {
    lock.withLock { value = true }
  }
}
