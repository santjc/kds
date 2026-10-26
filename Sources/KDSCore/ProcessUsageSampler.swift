import Darwin
import Foundation

/// Instantaneous resource usage for one process.
///
/// `cpuPercent` is a delta between two samples, so it is comparable to Activity Monitor's
/// CPU column and can exceed 100% on a multi-core machine. It is deliberately not `ps`'s
/// `%cpu`, which averages over the whole process lifetime. It is nil until there is a
/// recent baseline to measure from, which reads as "—" rather than a false 0%.
public struct ProcessUsage: Sendable, Equatable {
  public let cpuPercent: Double?
  public let residentBytes: UInt64
  public let memoryPercent: Double

  public init(cpuPercent: Double?, residentBytes: UInt64, memoryPercent: Double) {
    self.cpuPercent = cpuPercent
    self.residentBytes = residentBytes
    self.memoryPercent = memoryPercent
  }
}

extension ProcessUsage {
  /// Usage of a process tree: CPU, resident bytes and memory share summed. CPU is nil
  /// only when no process in the tree has a baseline yet. RSS counts shared pages once
  /// per process, so a tree's RAM reads somewhat above Activity Monitor's.
  public static func total(_ parts: [ProcessUsage]) -> ProcessUsage? {
    guard !parts.isEmpty else { return nil }
    let cpu = parts.compactMap(\.cpuPercent)
    return ProcessUsage(
      cpuPercent: cpu.isEmpty ? nil : cpu.reduce(0, +),
      residentBytes: parts.map(\.residentBytes).reduce(0, +),
      memoryPercent: parts.map(\.memoryPercent).reduce(0, +)
    )
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
    /// The process's start, in Mach ticks. A different start under the same PID is a
    /// different process.
    public let startTicks: UInt64

    public init(cpuNanoseconds: UInt64, uptimeNanoseconds: UInt64, startTicks: UInt64 = 0) {
      self.cpuNanoseconds = cpuNanoseconds
      self.uptimeNanoseconds = uptimeNanoseconds
      self.startTicks = startTicks
    }
  }

  /// A baseline older than this is discarded: the panel was closed in between, and a
  /// delta across minutes is an average, not the current load.
  public static let maximumBaselineAge: UInt64 = 10_000_000_000

  private var previous: [Int32: Reading] = [:]
  private let totalMemoryBytes: UInt64
  private let timebase: mach_timebase_info_data_t

  public init(totalMemoryBytes: UInt64 = ProcessInfo.processInfo.physicalMemory) {
    self.totalMemoryBytes = totalMemoryBytes
    var timebase = mach_timebase_info_data_t()
    mach_timebase_info(&timebase)
    self.timebase = timebase
  }

  public func sample(pids: [Int32]) async -> [Int32: ProcessUsage] {
    let now = DispatchTime.now().uptimeNanoseconds
    var usage: [Int32: ProcessUsage] = [:]
    var current: [Int32: Reading] = [:]

    for pid in pids {
      guard let reading = Self.read(pid: pid) else { continue }
      let sample = Reading(
        cpuNanoseconds: Self.nanoseconds(fromTicks: reading.cpuTicks, timebase: timebase),
        uptimeNanoseconds: now,
        startTicks: reading.startTicks)
      current[pid] = sample

      usage[pid] = ProcessUsage(
        cpuPercent: Self.cpuPercent(previous: previous[pid], current: sample),
        residentBytes: reading.residentBytes,
        memoryPercent: memoryPercent(residentBytes: reading.residentBytes)
      )
    }

    // Keeping only the PIDs just asked for bounds the baseline table.
    previous = current
    return usage
  }

  /// Pure delta math, isolated from `proc_pid_rusage` so it can be tested directly.
  /// Nil without a usable baseline: none yet, too old, or from a different process that
  /// held the same PID.
  public static func cpuPercent(previous: Reading?, current: Reading) -> Double? {
    guard let previous, previous.startTicks == current.startTicks else { return nil }
    guard current.uptimeNanoseconds > previous.uptimeNanoseconds,
      current.uptimeNanoseconds - previous.uptimeNanoseconds <= maximumBaselineAge,
      current.cpuNanoseconds >= previous.cpuNanoseconds
    else { return nil }

    let elapsed = current.uptimeNanoseconds - previous.uptimeNanoseconds
    let spent = current.cpuNanoseconds - previous.cpuNanoseconds
    return Double(spent) / Double(elapsed) * 100
  }

  /// `ri_user_time` and `ri_system_time` are Mach absolute-time ticks, not nanoseconds.
  /// On Intel a tick is a nanosecond; on Apple Silicon it is 125/3 ns, so skipping this
  /// conversion reads a pegged core as 2.4%.
  public static func nanoseconds(fromTicks ticks: UInt64, timebase: mach_timebase_info_data_t)
    -> UInt64
  {
    guard timebase.denom > 0 else { return ticks }
    let (product, overflow) = ticks.multipliedReportingOverflow(by: UInt64(timebase.numer))
    guard !overflow else { return ticks / UInt64(timebase.denom) * UInt64(timebase.numer) }
    return product / UInt64(timebase.denom)
  }

  private func memoryPercent(residentBytes: UInt64) -> Double {
    guard totalMemoryBytes > 0 else { return 0 }
    return min(100, Double(residentBytes) / Double(totalMemoryBytes) * 100)
  }

  private static func read(pid: Int32) -> (
    cpuTicks: UInt64, residentBytes: UInt64, startTicks: UInt64
  )? {
    var info = rusage_info_v4()
    let code = withUnsafeMutablePointer(to: &info) { pointer in
      pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { rebound in
        proc_pid_rusage(pid, RUSAGE_INFO_V4, rebound)
      }
    }
    guard code == 0 else { return nil }
    return (
      info.ri_user_time + info.ri_system_time, info.ri_resident_size, info.ri_proc_start_abstime
    )
  }
}
