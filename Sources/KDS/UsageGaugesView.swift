import KDSCore
import SwiftUI

struct UsageGaugesView: View {
  @EnvironmentObject private var usageStore: SystemUsageStore

  var body: some View {
    HStack(alignment: .top, spacing: 12) {
      UsageGauge(
        title: "CPU",
        fraction: usageStore.usage.cpuFraction,
        percent: usageStore.usage.cpuPercent,
        tint: Self.loadTint(for: usageStore.usage.cpuFraction),
        detail: "CPU \(Self.percentLabel(usageStore.usage.cpuPercent))"
      )

      UsageGauge(
        title: "GPU",
        fraction: usageStore.usage.gpuFraction,
        percent: usageStore.usage.gpuPercent,
        tint: Self.loadTint(for: usageStore.usage.gpuFraction),
        detail: gpuDetail
      )

      UsageGauge(
        title: "RAM",
        fraction: usageStore.usage.memoryFraction,
        percent: usageStore.usage.memoryPercent,
        tint: Self.pressureTint(for: usageStore.usage),
        detail: memoryDetail
      )
    }
    .padding(.horizontal, MenuMetrics.horizontalPadding)
    .padding(.bottom, 12)
  }

  private var gpuDetail: String {
    guard let percent = usageStore.usage.gpuPercent else {
      return "GPU utilisation is not reported by this machine"
    }
    return "GPU \(Self.percentLabel(percent))"
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

  /// The em dash is the honest reading when a counter is unavailable, not a zero.
  static func percentLabel(_ percent: Double?) -> String {
    guard let percent else { return "—" }
    return percentLabel(percent)
  }
}

private struct UsageGauge: View {
  let title: String
  let fraction: Double
  let percent: Double?
  let tint: Color
  let detail: String

  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  init(title: String, fraction: Double, percent: Double?, tint: Color, detail: String) {
    self.title = title
    self.fraction = fraction
    self.percent = percent
    self.tint = tint
    self.detail = detail
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 5) {
      HStack(spacing: 4) {
        Text(title)
          // Small text wants a touch of positive tracking to stay legible.
          .font(.caption2.weight(.semibold))
          .tracking(0.4)
          .foregroundStyle(.secondary)
        Spacer(minLength: 4)
        // Monospaced digits keep the number from resizing the column on every sample.
        Text(UsageGaugesView.percentLabel(percent))
          .font(.caption.monospacedDigit())
          .foregroundStyle(percent == nil ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.secondary))
      }

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
