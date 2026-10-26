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
    try expect((own.cpuPercent ?? 0) >= 0)
    try expect(own.memoryPercent > 0 && own.memoryPercent <= 100)
  },
  TestCase("reads a process pegging one core as about 100% CPU") {
    let busy = Process()
    busy.executableURL = URL(fileURLWithPath: "/usr/bin/yes")
    busy.standardOutput = FileHandle.nullDevice
    try busy.run()
    defer { busy.terminate() }

    let sampler = RusageProcessUsageSampler()
    _ = await sampler.sample(pids: [busy.processIdentifier])
    try await Task.sleep(for: .seconds(1))
    let usage = try require(await sampler.sample(pids: [busy.processIdentifier])[busy.processIdentifier])
    // A loaded machine may give `yes` well under a core, so the floor is low. It still
    // catches unconverted Mach ticks, which read a pegged core as 2.4%.
    let cpu = try require(usage.cpuPercent, "expected a CPU figure on the second sample")
    try expect(cpu > 10 && cpu < 150, "read \(cpu)%")
  },
  TestCase("counts a busy child against its idle parent's tree") {
    // `sh` sits idle in `wait` while its `yes` child pegs a core: the dev-server shape.
    let parent = Process()
    parent.executableURL = URL(fileURLWithPath: "/bin/sh")
    parent.arguments = ["-c", "/usr/bin/yes > /dev/null & wait"]
    try parent.run()
    defer {
      kill(-parent.processIdentifier, SIGTERM)
      parent.terminate()
    }
    try await Task.sleep(for: .milliseconds(300))

    let table = SysctlProcessTable()
    let sampler = RusageProcessUsageSampler()
    let pids = ProcessTree(await table.snapshot()).subtree(of: parent.processIdentifier)
    try expect(pids.count == 2, "expected sh and yes, got \(pids)")
    _ = await sampler.sample(pids: pids)
    try await Task.sleep(for: .seconds(1))
    let perPID = await sampler.sample(pids: pids)
    let total = try require(ProcessUsage.total(pids.compactMap { perPID[$0] }))
    let parentOnly = perPID[parent.processIdentifier]?.cpuPercent ?? 0

    for pid in pids where pid != parent.processIdentifier { kill(pid, SIGTERM) }
    let cpu = try require(total.cpuPercent)
    // Same low floor as above: under load `yes` may not get a whole core.
    try expect(parentOnly < 5, "the parent itself is idle")
    try expect(cpu > parentOnly + 10, "the tree carries the child's load, read \(cpu)%")
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
