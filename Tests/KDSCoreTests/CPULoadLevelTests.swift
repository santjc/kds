import KDSCore

let cpuLoadLevelTests: [TestCase] = [
  TestCase("maps CPU percent onto the six design bands") {
    let cases: [(Double, CPULoadLevel)] = [
      (0, .idle), (19.9, .idle), (20, .active), (45, .busy), (60, .hot), (80, .veryHot),
      (90, .critical), (100, .critical),
    ]
    for (percent, expected) in cases {
      let level = CPULoadLevel.level(for: percent, previous: nil)
      try expect(level == expected, "\(percent)% should be \(expected), got \(level)")
    }
  },
  TestCase("holds the current band until load clears the hysteresis margin") {
    try expect(CPULoadLevel.level(for: 21, previous: .idle) == .idle)
    try expect(CPULoadLevel.level(for: 23, previous: .idle) == .active)
    try expect(CPULoadLevel.level(for: 18, previous: .active) == .active)
    try expect(CPULoadLevel.level(for: 16.9, previous: .active) == .idle)
  },
  TestCase("jumps straight to a far band on a spike") {
    try expect(CPULoadLevel.level(for: 98, previous: .idle) == .critical)
    try expect(CPULoadLevel.level(for: 2, previous: .critical) == .idle)
  },
  TestCase("every band has a positive tempo that quickens with load") {
    let intervals = CPULoadLevel.allCases.map(\.frameInterval)
    try expect(intervals.allSatisfy { $0 > 0 })
    try expect(intervals == intervals.sorted(by: >))
  },
]
