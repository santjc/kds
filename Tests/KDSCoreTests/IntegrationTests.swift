import Darwin
import KDSCore

let integrationTests: [TestCase] = [
  TestCase("scans real listeners without duplicate identities") {
    let endpoints = try await LsofPortSource().snapshot()
    try expect(Set(endpoints.map(\.id)).count == endpoints.count)
    try expect(endpoints.allSatisfy { $0.ownerUID == getuid() })
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
