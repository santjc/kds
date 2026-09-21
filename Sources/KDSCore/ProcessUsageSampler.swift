import Darwin
import Foundation

/// Instantaneous resource usage for one process.
///
/// `cpuPercent` is a delta between two samples, so it is comparable to Activity Monitor's
/// CPU column and can exceed 100% on a multi-core machine. It is deliberately not `ps`'s
/// `%cpu`, which averages over the whole process lifetime.
public struct ProcessUsage: Sendable, Equatable {
  public let cpuPercent: Double
  public let residentBytes: UInt64
  public let memoryPercent: Double

  public init(cpuPercent: Double, residentBytes: UInt64, memoryPercent: Double) {
    self.cpuPercent = cpuPercent
    self.residentBytes = residentBytes
    self.memoryPercent = memoryPercent
  }
}

public protocol ProcessUsageSampling: Sendable {
  func sample(pids: [Int32]) async -> [Int32: ProcessUsage]
}

/// Samples per-process CPU time and resident size through `proc_pid_rusage`.
/// No shell, and no privileges beyond reading the current user's own processes.
public actor RusageProcessUsageSampler: ProcessUsageSampling {
  public struct Reading: Sendable, Equatable {
    public let cpuNanoseconds: UInt64
    public let uptimeNanoseconds: UInt64

    public init(cpuNanoseconds: UInt64, uptimeNanoseconds: UInt64) {
      self.cpuNanoseconds = cpuNanoseconds
      self.uptimeNanoseconds = uptimeNanoseconds
    }
  }

  private var previous: [Int32: Reading] = [:]
  private let totalMemoryBytes: UInt64

  public init(totalMemoryBytes: UInt64 = ProcessInfo.processInfo.physicalMemory) {
    self.totalMemoryBytes = totalMemoryBytes
  }

  public func sample(pids: [Int32]) async -> [Int32: ProcessUsage] {
    let now = DispatchTime.now().uptimeNanoseconds
    var usage: [Int32: ProcessUsage] = [:]
    var current: [Int32: Reading] = [:]

    for pid in pids {
      guard let reading = Self.read(pid: pid) else { continue }
      let sample = Reading(cpuNanoseconds: reading.cpuNanoseconds, uptimeNanoseconds: now)
      current[pid] = sample

      usage[pid] = ProcessUsage(
        cpuPercent: Self.cpuPercent(previous: previous[pid], current: sample),
        residentBytes: reading.residentBytes,
        memoryPercent: memoryPercent(residentBytes: reading.residentBytes)
      )
    }

    // Dropping vanished PIDs keeps a recycled PID from inheriting a stale baseline.
    previous = current
    return usage
  }

  /// Pure delta math, isolated from `proc_pid_rusage` so it can be tested directly.
  /// The first sample for a PID reads zero, since a rate needs two points.
  public static func cpuPercent(previous: Reading?, current: Reading) -> Double {
    guard let previous else { return 0 }
    guard current.uptimeNanoseconds > previous.uptimeNanoseconds,
      current.cpuNanoseconds >= previous.cpuNanoseconds
    else { return 0 }

    let elapsed = current.uptimeNanoseconds - previous.uptimeNanoseconds
    let spent = current.cpuNanoseconds - previous.cpuNanoseconds
    return Double(spent) / Double(elapsed) * 100
  }

  private func memoryPercent(residentBytes: UInt64) -> Double {
    guard totalMemoryBytes > 0 else { return 0 }
    return min(100, Double(residentBytes) / Double(totalMemoryBytes) * 100)
  }

  private static func read(pid: Int32) -> (cpuNanoseconds: UInt64, residentBytes: UInt64)? {
    var info = rusage_info_v4()
    let code = withUnsafeMutablePointer(to: &info) { pointer in
      pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { rebound in
        proc_pid_rusage(pid, RUSAGE_INFO_V4, rebound)
      }
    }
    guard code == 0 else { return nil }
    return (info.ri_user_time + info.ri_system_time, info.ri_resident_size)
  }
}
