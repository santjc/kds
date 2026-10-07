import Foundation

/// The six moods of the menu bar mascot, one per CPU band on the design boards.
public enum CPULoadLevel: Int, CaseIterable, Sendable, Comparable {
  case idle
  case active
  case busy
  case hot
  case veryHot
  case critical

  /// The sprite name prefix, matching the frames `Scripts/cut-sprites.swift` writes.
  public var spriteName: String {
    switch self {
    case .idle: "idle"
    case .active: "active"
    case .busy: "busy"
    case .hot: "hot"
    case .veryHot: "very_hot"
    case .critical: "critical"
    }
  }

  public var frameCount: Int {
    switch self {
    case .idle, .active: 4
    case .busy, .hot: 6
    case .veryHot, .critical: 8
    }
  }

  /// Seconds per frame. Load reads in the tempo as well as the drawing, so the mascot
  /// breathes when idle and scrambles when the machine is pegged.
  public var frameInterval: Double {
    switch self {
    case .idle: 0.5
    case .active: 0.25
    case .busy: 0.16
    case .hot: 0.12
    case .veryHot: 0.09
    case .critical: 0.07
    }
  }

  /// Lower bound of each band, in CPU percent.
  public var lowerBound: Double {
    switch self {
    case .idle: 0
    case .active: 20
    case .busy: 40
    case .hot: 60
    case .veryHot: 75
    case .critical: 90
    }
  }

  public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

  /// The band for `percent`, with hysteresis: leaving the current band needs a margin of
  /// `hysteresis` points past its edge, so a load hovering on a boundary does not make
  /// the icon flicker between two moods every sample.
  public static func level(
    for percent: Double, previous: CPULoadLevel?, hysteresis: Double = 3
  ) -> CPULoadLevel {
    let raw = allCases.last { percent >= $0.lowerBound } ?? .idle
    guard let previous, raw != previous else { return raw }

    if raw > previous {
      let next = allCases[previous.rawValue + 1]
      return percent >= next.lowerBound + hysteresis ? raw : previous
    }
    return percent < previous.lowerBound - hysteresis ? raw : previous
  }
}

/// Machine-wide CPU only, for the always-on menu bar icon. The full `SystemUsage` sample
/// also reads memory and the GPU registry, which only the open panel needs.
public actor CPULoadSampler {
  private var previousTicks: CPUTicks?

  public init() {}

  public func sample() -> Double {
    guard let ticks = HostSystemMetricsSampler.readCPUTicks() else { return 0 }
    defer { previousTicks = ticks }
    return HostSystemMetricsSampler.cpuPercent(previous: previousTicks, current: ticks)
  }
}
