import Darwin
import KDSCore

let systemMetricsTests: [TestCase] = [
  TestCase("first sample reports zero CPU") {
    let value = HostSystemMetricsSampler.cpuPercent(
      previous: nil,
      current: CPUTicks(busy: 100, total: 400)
    )
    try expect(value == 0)
  },
  TestCase("reports the busy share of the tick delta") {
    let value = HostSystemMetricsSampler.cpuPercent(
      previous: CPUTicks(busy: 100, total: 400),
      current: CPUTicks(busy: 125, total: 500)
    )
    try expect(value == 25, "got \(value)")
  },
  TestCase("idle machines report zero") {
    let value = HostSystemMetricsSampler.cpuPercent(
      previous: CPUTicks(busy: 100, total: 400),
      current: CPUTicks(busy: 100, total: 500)
    )
    try expect(value == 0)
  },
  TestCase("a zero tick delta does not divide by zero") {
    let value = HostSystemMetricsSampler.cpuPercent(
      previous: CPUTicks(busy: 100, total: 400),
      current: CPUTicks(busy: 100, total: 400)
    )
    try expect(value == 0)
  },
  TestCase("counter resets report zero instead of a bogus spike") {
    let value = HostSystemMetricsSampler.cpuPercent(
      previous: CPUTicks(busy: 100, total: 400),
      current: CPUTicks(busy: 10, total: 40)
    )
    try expect(value == 0)
  },
  TestCase("memory fraction is derived from used over total") {
    let usage = SystemUsage(
      cpuPercent: 0,
      memoryUsedBytes: 8 * 1024 * 1024 * 1024,
      memoryTotalBytes: 16 * 1024 * 1024 * 1024
    )
    try expect(usage.memoryFraction == 0.5, "got \(usage.memoryFraction)")
    try expect(usage.memoryPercent == 50)
  },
  TestCase("a zero memory total does not divide by zero") {
    let usage = SystemUsage(memoryUsedBytes: 1024, memoryTotalBytes: 0)
    try expect(usage.memoryFraction == 0)
  },
]

let processUsageTests: [TestCase] = [
  TestCase("converts Apple Silicon Mach ticks to nanoseconds") {
    let appleSilicon = mach_timebase_info_data_t(numer: 125, denom: 3)
    try expect(RusageProcessUsageSampler.nanoseconds(fromTicks: 24_000_000, timebase: appleSilicon) == 1_000_000_000)
    let intel = mach_timebase_info_data_t(numer: 1, denom: 1)
    try expect(RusageProcessUsageSampler.nanoseconds(fromTicks: 42, timebase: intel) == 42)
  },
  TestCase("does not overflow on a long-lived process") {
    let appleSilicon = mach_timebase_info_data_t(numer: 125, denom: 3)
    let ticks = UInt64.max / 100
    let nanos = RusageProcessUsageSampler.nanoseconds(fromTicks: ticks, timebase: appleSilicon)
    try expect(nanos > ticks, "conversion must still scale up, not wrap")
  },
  TestCase("per-process CPU is the CPU-time delta over wall time") {
    let previous = RusageProcessUsageSampler.Reading(cpuNanoseconds: 0, uptimeNanoseconds: 0)
    let current = RusageProcessUsageSampler.Reading(
      cpuNanoseconds: 1_500_000_000, uptimeNanoseconds: 1_000_000_000)
    try expect(RusageProcessUsageSampler.cpuPercent(previous: previous, current: current) == 150)
  },
  TestCase("per-process CPU has no value without a usable baseline") {
    let current = RusageProcessUsageSampler.Reading(
      cpuNanoseconds: 2_000_000_000, uptimeNanoseconds: 60_000_000_000, startTicks: 7)
    let recent = RusageProcessUsageSampler.Reading(
      cpuNanoseconds: 1_000_000_000, uptimeNanoseconds: 58_000_000_000, startTicks: 7)
    let stale = RusageProcessUsageSampler.Reading(
      cpuNanoseconds: 1_000_000_000, uptimeNanoseconds: 1_000_000_000, startTicks: 7)
    let otherProcess = RusageProcessUsageSampler.Reading(
      cpuNanoseconds: 1_000_000_000, uptimeNanoseconds: 58_000_000_000, startTicks: 8)

    try expect(RusageProcessUsageSampler.cpuPercent(previous: recent, current: current) == 50)
    try expect(RusageProcessUsageSampler.cpuPercent(previous: nil, current: current) == nil)
    try expect(
      RusageProcessUsageSampler.cpuPercent(previous: stale, current: current) == nil,
      "a minute-old baseline is an average, not the current load")
    try expect(
      RusageProcessUsageSampler.cpuPercent(previous: otherProcess, current: current) == nil,
      "a recycled PID must not inherit the old process's baseline")
  },
]
