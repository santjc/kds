import KDSCore

let memoryClassifierTests: [TestCase] = [
  TestCase("never allows KDS itself") {
    let result = memoryClassifier.classify(
      process: memoryProcess(pid: 999, path: "/Applications/KDS.app/Contents/MacOS/KDS"),
      override: .include
    )
    try expect(result.category == .protected)
  },
  TestCase("protects processes owned by another user") {
    let result = memoryClassifier.classify(
      process: memoryProcess(path: "/opt/homebrew/bin/node", uid: 0),
      override: nil
    )
    try expect(result.category == .protected)
  },
  TestCase("protects critical processes by name") {
    for path in ["/usr/libexec/nope/WindowServer", "/somewhere/Finder"] {
      let result = memoryClassifier.classify(process: memoryProcess(path: path), override: .include)
      try expect(result.category == .protected, "\(path) should be protected")
    }
  },
  TestCase("protects macOS system paths") {
    let result = memoryClassifier.classify(
      process: memoryProcess(path: "/System/Library/CoreServices/Spotlight"),
      override: .include
    )
    try expect(result.category == .protected)
  },
  TestCase("classifies development runtimes as development") {
    let result = memoryClassifier.classify(
      process: memoryProcess(path: "/opt/homebrew/bin/node"),
      override: nil
    )
    try expect(result.category == .development, "got \(result.category)")
  },
  TestCase("app bundles stay killable, unlike on the ports tab") {
    let result = memoryClassifier.classify(
      process: memoryProcess(path: "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"),
      override: nil
    )
    try expect(result.category == .other, "got \(result.category)")
  },
  TestCase("keeps local services out of the development group") {
    let result = memoryClassifier.classify(
      process: memoryProcess(path: "/opt/homebrew/bin/postgres"),
      override: nil
    )
    try expect(result.category == .other)
  },
  TestCase("applies manual overrides") {
    let process = memoryProcess(path: "/opt/homebrew/bin/some-daemon")

    try expect(memoryClassifier.classify(process: process, override: .include).category == .development)
    try expect(memoryClassifier.classify(process: process, override: .protect).category == .protected)
  },
  TestCase("unrecognized processes are background processes") {
    let result = memoryClassifier.classify(
      process: memoryProcess(path: "/opt/homebrew/bin/some-daemon"),
      override: nil
    )
    try expect(result.category == .other)
    try expect(result.reason == "Background process", "got \(result.reason)")
  },
]

private let memoryClassifier = MemoryClassifier(currentUID: 501, ownPID: 999)

private func memoryProcess(
  pid: Int32 = 42,
  path: String,
  uid: UInt32 = 501
) -> MemoryProcess {
  MemoryProcess(
    pid: pid,
    processName: PSProcessParser.processName(fromPath: path),
    commandPath: path,
    residentBytes: 500 * 1024 * 1024,
    cpuPercent: 1,
    ownerUID: uid
  )
}
