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
