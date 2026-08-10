import KDSCore

let lsofParserTests: [TestCase] = [
  TestCase("parses and sorts current-user listeners") {
    let output = """
      p42
      cnode
      u501
      Ldev
      f10
      n*:3000
      p7
      cpython3
      u501
      Ldev
      f8
      n127.0.0.1:8080
      """
    let endpoints = LsofParser.parse(output, currentUID: 501)

    try expect(endpoints.map(\.port) == [3000, 8080])
    try expect(endpoints[0].processName == "node")
    try expect(endpoints[1].addresses == ["127.0.0.1"])
  },
  TestCase("merges IPv4 and IPv6") {
    let output = """
      p42
      cnode
      u501
      f10
      n127.0.0.1:3000
      f11
      n[::1]:3000
      """
    let endpoints = LsofParser.parse(output, currentUID: 501)

    try expect(endpoints.count == 1)
    try expect(endpoints[0].addresses == ["127.0.0.1", "::1"])
  },
  TestCase("ignores other users and malformed records") {
    let output = """
      p42
      cnode
      u502
      n*:3000
      pbroken
      cunknown
      u501
      nnot-a-listener
      """

    try expect(LsofParser.parse(output, currentUID: 501).isEmpty)
  },
  TestCase("handles Unicode and multiple ports") {
    let output = """
      p42
      cdév-server
      u501
      Ldéveloppeur
      n*:3001
      n*:4000
      """
    let endpoints = LsofParser.parse(output, currentUID: 501)

    try expect(endpoints.map(\.port) == [3001, 4000])
    try expect(endpoints.allSatisfy { $0.processName == "dév-server" })
  },
]
