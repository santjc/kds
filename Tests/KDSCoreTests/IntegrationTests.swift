import Darwin
import KDSCore

let integrationTests: [TestCase] = [
  TestCase("scans real listeners without duplicate identities") {
    let endpoints = try await LsofPortSource().snapshot()
    try expect(Set(endpoints.map(\.id)).count == endpoints.count)
    try expect(endpoints.allSatisfy { $0.ownerUID == getuid() })
  },
  TestCase("scans real memory usage and finds itself") {
    let processes = try await PSProcessMemorySource().snapshot()
    try expect(!processes.isEmpty)
    try expect(processes.allSatisfy { $0.ownerUID == getuid() })
    try expect(Set(processes.map(\.pid)).count == processes.count)
    try expect(processes.contains { $0.pid == getpid() }, "expected the test process in the list")
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
