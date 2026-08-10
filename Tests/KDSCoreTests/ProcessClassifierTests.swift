import KDSCore

let processClassifierTests: [TestCase] = [
  TestCase("classifies project processes as development") {
    let result = classifier.classify(
      endpoint: endpoint(process: "my-server"),
      details: details(path: "/tmp/my-server", project: "/Users/dev/project"),
      override: nil
    )
    try expect(result.category == .development)
  },
  TestCase("protects GUI and system processes") {
    let gui = classifier.classify(
      endpoint: endpoint(process: "ControlCenter"),
      details: details(
        path: "/System/Library/CoreServices/ControlCenter.app/Contents/MacOS/ControlCenter"),
      override: nil
    )
    let app = classifier.classify(
      endpoint: endpoint(process: "Spotify"),
      details: details(path: "/Applications/Spotify.app/Contents/MacOS/Spotify"),
      override: nil
    )
    try expect(gui.category == .protected)
    try expect(app.category == .protected)
  },
  TestCase("keeps databases out of Kill All") {
    let result = classifier.classify(
      endpoint: endpoint(process: "postgres"),
      details: details(path: "/opt/homebrew/bin/postgres"),
      override: nil
    )
    try expect(result.category == .other)
  },
  TestCase("applies manual overrides") {
    let unknown = endpoint(process: "custom")
    let processDetails = details(path: "/usr/local/bin/custom")

    try expect(
      classifier.classify(
        endpoint: unknown,
        details: processDetails,
        override: .include
      ).category == .development)
    try expect(
      classifier.classify(
        endpoint: unknown,
        details: processDetails,
        override: .protect
      ).category == .protected)
  },
  TestCase("never allows KDS itself") {
    let result = classifier.classify(
      endpoint: endpoint(pid: 999, process: "KDS"),
      details: details(path: "/Applications/KDS.app/Contents/MacOS/KDS"),
      override: .include
    )
    try expect(result.category == .protected)
  },
  TestCase("never includes a system app in Kill All") {
    let result = classifier.classify(
      endpoint: endpoint(process: "ControlCenter"),
      details: details(
        path: "/System/Library/CoreServices/ControlCenter.app/Contents/MacOS/ControlCenter"
      ),
      override: .include
    )
    try expect(result.category == .protected)
  },
]

private let classifier = ProcessClassifier(currentUID: 501, ownPID: 999)

private func endpoint(pid: Int32 = 42, process: String) -> ListeningEndpoint {
  ListeningEndpoint(port: 3000, pid: pid, ownerUID: 501, processName: process)
}

private func details(path: String?, project: String? = nil) -> ProcessDetails {
  ProcessDetails(executablePath: path, workingDirectory: project, projectRoot: project)
}
