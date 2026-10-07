import Darwin
import Foundation
import KDSCore

let integrationTests: [TestCase] = [
  TestCase("scans real listeners without duplicate identities") {
    let endpoints = try await LsofPortSource().snapshot()
    try expect(Set(endpoints.map(\.id)).count == endpoints.count)
    try expect(endpoints.allSatisfy { $0.ownerUID == getuid() })
  },
  TestCase("samples real per-process CPU and memory for itself") {
    let sampler = RusageProcessUsageSampler()
    _ = await sampler.sample(pids: [getpid()])
    try await Task.sleep(for: .milliseconds(200))
    let usage = await sampler.sample(pids: [getpid()])

    let own = try require(usage[getpid()], "expected usage for the test process")
    try expect(own.residentBytes > 0)
    try expect(own.cpuPercent >= 0)
    try expect(own.memoryPercent > 0 && own.memoryPercent <= 100)
  },
  TestCase("reads the real process table, argv included, and finds itself") {
    let table = await SysctlProcessTable().snapshot()
    let own = try require(table.first { $0.pid == getpid() }, "expected the test process")
    try expect(own.parentPID > 0)
    try expect(own.arguments.first?.contains("KDSCoreTests") == true)
    try expect(own.startDate < Date() && own.startDate > Date().addingTimeInterval(-3600))
    try expect(table.allSatisfy { $0.ownerUID == getuid() })
    _ = BackgroundProcessClassifier().classify(table)
  },
  TestCase("samples real CPU and memory") {
    let sampler = HostSystemMetricsSampler()
    _ = await sampler.sample()
    try await Task.sleep(for: .milliseconds(200))
    let usage = await sampler.sample()

    try expect(usage.memoryTotalBytes > 0)
    try expect(usage.memoryUsedBytes > 0)
    try expect(usage.memoryFraction > 0 && usage.memoryFraction <= 1)
    try expect(usage.cpuPercent >= 0 && usage.cpuPercent <= 100)
    if let gpu = usage.gpuPercent {
      try expect(gpu >= 0 && gpu <= 100)
    }
  },
  TestCase("enforces command timeouts") {
    do {
      _ = try await SystemCommandRunner().run(
        executable: "/bin/sleep",
        arguments: ["1"],
        timeout: 0.05
      )
      try expect(false, "Expected a timeout")
    } catch CommandRunnerError.timedOut {
    }
  },
  TestCase("reports missing processes without sending a valid signal") {
    let result = await SystemProcessTerminator().terminate(
      pid: Int32.max,
      signal: .graceful
    )
    try expect(result == .notFound)
  },
  TestCase("inspects its own executable and project directory") {
    let details = await SystemProcessInspector().inspect(pid: getpid())
    try expect(details.executablePath != nil)
    try expect(details.workingDirectory != nil)
    try expect(details.projectRoot != nil)
  },
]
