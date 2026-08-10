import Darwin
import Foundation

public enum TerminationSignal: Sendable {
  case graceful
  case force

  var rawValue: Int32 {
    switch self {
    case .graceful: SIGTERM
    case .force: SIGKILL
    }
  }
}

public enum TerminationResult: Equatable, Sendable {
  case success
  case notFound
  case permissionDenied
  case failed(Int32)
}

public protocol ProcessTerminating: Sendable {
  func terminate(pid: Int32, signal: TerminationSignal) async -> TerminationResult
}

public struct SystemProcessTerminator: ProcessTerminating {
  public init() {}

  public func terminate(pid: Int32, signal: TerminationSignal) async -> TerminationResult {
    guard Darwin.kill(pid, signal.rawValue) == 0 else {
      switch errno {
      case ESRCH: return .notFound
      case EPERM: return .permissionDenied
      default: return .failed(errno)
      }
    }
    return .success
  }
}
