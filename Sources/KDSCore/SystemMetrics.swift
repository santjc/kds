import Darwin
import Foundation

public enum MemoryPressure: Sendable, Equatable {
  case normal
  case warning
  case critical
}

/// A point-in-time reading of machine-wide CPU and memory usage.
public struct SystemUsage: Sendable, Equatable {
  public let cpuPercent: Double
  public let memoryUsedBytes: UInt64
  public let memoryTotalBytes: UInt64
  public let pressure: MemoryPressure

  public init(
    cpuPercent: Double = 0,
    memoryUsedBytes: UInt64 = 0,
    memoryTotalBytes: UInt64 = 0,
    pressure: MemoryPressure = .normal
  ) {
    self.cpuPercent = cpuPercent
    self.memoryUsedBytes = memoryUsedBytes
    self.memoryTotalBytes = memoryTotalBytes
    self.pressure = pressure
  }

  public var cpuFraction: Double { min(1, max(0, cpuPercent / 100)) }

  public var memoryFraction: Double {
    guard memoryTotalBytes > 0 else { return 0 }
    return min(1, Double(memoryUsedBytes) / Double(memoryTotalBytes))
  }

  public var memoryPercent: Double { memoryFraction * 100 }
}

/// Cumulative scheduler ticks, summed across all cores.
public struct CPUTicks: Sendable, Equatable {
  public let busy: UInt64
  public let total: UInt64

  public init(busy: UInt64, total: UInt64) {
    self.busy = busy
    self.total = total
  }
}

public protocol SystemMetricsSampling: Sendable {
  func sample() async -> SystemUsage
}

/// Samples CPU and memory through Mach host calls. No shell, no elevated privileges.
public actor HostSystemMetricsSampler: SystemMetricsSampling {
  private var previousTicks: CPUTicks?

  public init() {}

  public func sample() async -> SystemUsage {
    let ticks = Self.readCPUTicks()
    let cpu: Double
    if let ticks {
      cpu = Self.cpuPercent(previous: previousTicks, current: ticks)
      previousTicks = ticks
    } else {
      cpu = 0
    }

    let memory = Self.readMemory()
    return SystemUsage(
      cpuPercent: cpu,
      memoryUsedBytes: memory.used,
      memoryTotalBytes: memory.total,
      pressure: Self.readPressure()
    )
  }

  /// Pure tick math, isolated from Mach so it can be tested directly.
  /// Returns zero for the first sample and for any counter reset.
  public static func cpuPercent(previous: CPUTicks?, current: CPUTicks) -> Double {
    guard let previous else { return 0 }
    guard current.total >= previous.total, current.busy >= previous.busy else { return 0 }

    let deltaTotal = current.total - previous.total
    guard deltaTotal > 0 else { return 0 }

    let deltaBusy = current.busy - previous.busy
    return min(100, max(0, Double(deltaBusy) / Double(deltaTotal) * 100))
  }

  private static func readCPUTicks() -> CPUTicks? {
    var cpuCount: natural_t = 0
    var info: processor_info_array_t?
    var infoCount: mach_msg_type_number_t = 0

    let result = host_processor_info(
      mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &cpuCount, &info, &infoCount)
    guard result == KERN_SUCCESS, let info else { return nil }
    defer {
      vm_deallocate(
        mach_task_self_,
        vm_address_t(UInt(bitPattern: info)),
        vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.size)
      )
    }

    var busy: UInt64 = 0
    var total: UInt64 = 0
    for index in 0..<Int(cpuCount) {
      let base = index * Int(CPU_STATE_MAX)
      let user = UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_USER)]))
      let system = UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_SYSTEM)]))
      let nice = UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_NICE)]))
      let idle = UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_IDLE)]))
      busy += user + system + nice
      total += user + system + nice + idle
    }
    return CPUTicks(busy: busy, total: total)
  }

  private static func readMemory() -> (used: UInt64, total: UInt64) {
    let total = ProcessInfo.processInfo.physicalMemory

    var stats = vm_statistics64_data_t()
    var count = mach_msg_type_number_t(
      MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
    let result = withUnsafeMutablePointer(to: &stats) { pointer in
      pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
        host_statistics64(mach_host_self(), HOST_VM_INFO64, rebound, &count)
      }
    }
    guard result == KERN_SUCCESS else { return (0, total) }

    // Matches Activity Monitor's "Memory Used": app memory + wired + compressed.
    var hostPageSize: vm_size_t = 0
    guard host_page_size(mach_host_self(), &hostPageSize) == KERN_SUCCESS else {
      return (0, total)
    }
    let pageSize = UInt64(hostPageSize)
    let used =
      (UInt64(stats.active_count) + UInt64(stats.wire_count)
        + UInt64(stats.compressor_page_count)) * pageSize
    return (min(used, total), total)
  }

  private static func readPressure() -> MemoryPressure {
    var level: Int32 = 0
    var size = MemoryLayout<Int32>.size
    guard sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) == 0 else {
      return .normal
    }
    switch level {
    case 4: return .critical
    case 2: return .warning
    default: return .normal
    }
  }
}
