import KDSCore
import SwiftUI

struct UsageGaugesView: View {
  @EnvironmentObject private var usageStore: SystemUsageStore

  var body: some View {
    HStack(spacing: 14) {
      UsageGauge(
        systemName: "cpu",
        title: "CPU",
        fraction: usageStore.usage.cpuFraction,
        percent: usageStore.usage.cpuPercent,
        tint: Self.loadTint(for: usageStore.usage.cpuFraction),
        detail: "CPU \(Self.percentLabel(usageStore.usage.cpuPercent))"
      )

      UsageGauge(
        systemName: "memorychip",
        title: "Memory",
        fraction: usageStore.usage.memoryFraction,
        percent: usageStore.usage.memoryPercent,
        tint: Self.pressureTint(for: usageStore.usage),
        detail: memoryDetail
      )
    }
    .padding(.horizontal, MenuMetrics.horizontalPadding)
    .padding(.bottom, 10)
  }

  private var memoryDetail: String {
    let usage = usageStore.usage
    guard usage.memoryTotalBytes > 0 else { return "Memory" }
    let formatter = ByteCountFormatter()
    formatter.allowedUnits = [.useGB]
    formatter.countStyle = .memory
    let used = formatter.string(fromByteCount: Int64(usage.memoryUsedBytes))
    let total = formatter.string(fromByteCount: Int64(usage.memoryTotalBytes))
    return "Memory \(used) of \(total)"
  }

  /// Colour encodes state rather than decorating: quiet until it is worth noticing.
  static func loadTint(for fraction: Double) -> Color {
    switch fraction {
    case ..<0.6: .secondary
    case ..<0.85: .orange
    default: .red
    }
  }

  static func pressureTint(for usage: SystemUsage) -> Color {
    switch usage.pressure {
    case .normal: loadTint(for: usage.memoryFraction)
    case .warning: .orange
    case .critical: .red
    }
  }

  static func percentLabel(_ percent: Double) -> String {
    "\(Int(percent.rounded()))%"
  }
}

private struct UsageGauge: View {
  let systemName: String
  let title: String
  let fraction: Double
  let percent: Double
  let tint: Color
  let detail: String

  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    HStack(spacing: 6) {
      Image(systemName: systemName)
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(.secondary)
        .frame(width: 14)

      GeometryReader { proxy in
        ZStack(alignment: .leading) {
          Capsule()
            .fill(Color.primary.opacity(0.08))
          Capsule()
            .fill(tint.opacity(0.85))
            .frame(width: max(2, proxy.size.width * min(1, max(0, fraction))))
        }
      }
      .frame(height: 6)

      // Monospaced digits keep the number from resizing the bar on every sample.
      Text(UsageGaugesView.percentLabel(percent))
        .font(.caption.monospacedDigit())
        .foregroundStyle(.secondary)
        .frame(width: 32, alignment: .trailing)
    }
    // Critically damped: the value is not gesture-driven, so overshoot would be wrong.
    .animation(reduceMotion ? nil : .spring(duration: 0.4, bounce: 0), value: fraction)
    .frame(maxWidth: .infinity)
    .help(detail)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("\(title) usage")
    .accessibilityValue(detail)
  }
}
