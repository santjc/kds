import KDSCore

let psProcessParserTests: [TestCase] = [
  TestCase("parses ps output and converts RSS to bytes") {
    let output = """
        512    501   3.4  262144 /Applications/Safari.app/Contents/MacOS/Safari
      """
    let processes = PSProcessParser.parse(output, currentUID: 501)

    try expect(processes.count == 1, "expected one process, got \(processes.count)")
    let process = try require(processes.first)
    try expect(process.pid == 512)
    try expect(process.residentBytes == 262_144 * 1024)
    try expect(process.cpuPercent == 3.4)
    try expect(process.processName == "Safari")
    try expect(process.commandPath == "/Applications/Safari.app/Contents/MacOS/Safari")
  },
  TestCase("drops processes owned by other users") {
    let output = """
        512    501   1.0  100000 /usr/bin/mine
        513      0   1.0  900000 /usr/sbin/notmine
      """
    let processes = PSProcessParser.parse(output, currentUID: 501)

    try expect(processes.count == 1)
    try expect(processes.first?.pid == 512)
  },
  TestCase("keeps command paths that contain spaces") {
    let output = """
        700    501   0.0   50000 /Applications/Visual Studio Code.app/Contents/MacOS/Electron
      """
    let processes = PSProcessParser.parse(output, currentUID: 501)
    let process = try require(processes.first)

    try expect(
      process.commandPath == "/Applications/Visual Studio Code.app/Contents/MacOS/Electron",
      "got \(process.commandPath)")
    try expect(process.processName == "Electron")
  },
  TestCase("sorts by resident size descending") {
    let output = """
        1    501   0.0   10000 /usr/bin/small
        2    501   0.0  900000 /usr/bin/large
        3    501   0.0  450000 /usr/bin/medium
      """
    let processes = PSProcessParser.parse(output, currentUID: 501)

    try expect(processes.map(\.pid) == [2, 3, 1], "got \(processes.map(\.pid))")
  },
  TestCase("ignores malformed and short lines") {
    let output = """
        1    501   0.0
        notanumber 501 0.0 1000 /usr/bin/x
        2    501   0.0   10000 /usr/bin/ok

      """
    let processes = PSProcessParser.parse(output, currentUID: 501)

    try expect(processes.count == 1, "got \(processes.count)")
    try expect(processes.first?.pid == 2)
  },
  TestCase("keeps bare command names that are not paths") {
    let output = """
        9    501   0.0   30000 kernel_managerd
      """
    let processes = PSProcessParser.parse(output, currentUID: 501)

    try expect(processes.first?.processName == "kernel_managerd")
  },
]
