import AppKit
import SwiftUI

enum MenuMetrics {
  static let width: CGFloat = 410
  static let horizontalPadding: CGFloat = 12
  static let controlSize: CGFloat = 28
  static let rowHeight: CGFloat = 40
  static let portWidth: CGFloat = 54
  /// One width for the CPU and RAM columns so the header and every row align.
  static let metricWidth: CGFloat = 48

  /// The panel grows with its content and only scrolls past this point.
  static let maxContentHeight: CGFloat = 420
}

/// Reports the natural height of a view so the panel can size itself to fit.
struct ContentHeightKey: PreferenceKey {
  static let defaultValue: CGFloat = 0

  static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
    value = max(value, nextValue())
  }
}

/// A scroll view that adopts its content's height until `maxHeight`, then scrolls.
struct SelfSizingScrollView<Content: View>: View {
  var maxHeight: CGFloat = MenuMetrics.maxContentHeight
  @ViewBuilder var content: Content
  @State private var contentHeight: CGFloat = 0

  var body: some View {
    ScrollView {
      content
        .background(
          GeometryReader { proxy in
            Color.clear.preference(key: ContentHeightKey.self, value: proxy.size.height)
          }
        )
    }
    .frame(height: min(max(contentHeight, 1), maxHeight))
    .scrollDisabled(contentHeight <= maxHeight)
    .onPreferenceChange(ContentHeightKey.self) { height in
      guard abs(height - contentHeight) > 0.5 else { return }
      contentHeight = height
    }
  }
}

struct IconControlLabel: View {
  let systemName: String
  let title: String
  var color: Color = .secondary

  var body: some View {
    Image(systemName: systemName)
      .font(.system(size: 12, weight: .medium))
      .foregroundStyle(color.opacity(0.82))
      .frame(width: MenuMetrics.controlSize, height: MenuMetrics.controlSize)
      .contentShape(Rectangle())
      .accessibilityLabel(title)
  }
}

struct InteractiveIconControlModifier: ViewModifier {
  @State private var isHovering = false

  func body(content: Content) -> some View {
    content
      .background(
        isHovering ? Color.primary.opacity(0.065) : Color.clear,
        in: RoundedRectangle(cornerRadius: 6)
      )
      .onHover { hovering in
        guard hovering != isHovering else { return }
        isHovering = hovering
        if hovering {
          NSCursor.pointingHand.push()
        } else {
          NSCursor.pop()
        }
      }
      .onDisappear {
        guard isHovering else { return }
        NSCursor.pop()
        isHovering = false
      }
  }
}

struct PointingHandCursorModifier: ViewModifier {
  @State private var isHovering = false

  func body(content: Content) -> some View {
    content
      .onHover { hovering in
        guard hovering != isHovering else { return }
        isHovering = hovering
        if hovering {
          NSCursor.pointingHand.push()
        } else {
          NSCursor.pop()
        }
      }
      .onDisappear {
        guard isHovering else { return }
        NSCursor.pop()
        isHovering = false
      }
  }
}

extension View {
  func interactiveIconControl() -> some View {
    modifier(InteractiveIconControlModifier())
  }

  func pointingHandCursor() -> some View {
    modifier(PointingHandCursorModifier())
  }
}

struct ErrorBanner: View {
  let message: String

  var body: some View {
    Label(message, systemImage: "exclamationmark.triangle.fill")
      .font(.caption)
      .foregroundStyle(.orange)
      .padding(8)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
  }
}

/// A collapsible `Section (n)` header.
struct DisclosureHeader: View {
  let title: String
  let count: Int
  @Binding var isExpanded: Bool
  @State private var isHovering = false

  var body: some View {
    Button {
      isExpanded.toggle()
    } label: {
      HStack(spacing: 6) {
        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
          .font(.system(size: 9, weight: .semibold))
          .frame(width: 10)
        Text("\(title) (\(count))")
          .font(.caption.weight(.semibold))
        Spacer()
      }
      .foregroundStyle(.secondary)
      .padding(.horizontal, 6)
      .frame(minHeight: MenuMetrics.controlSize)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .background(
      isHovering ? Color.primary.opacity(0.045) : Color.clear,
      in: RoundedRectangle(cornerRadius: 6)
    )
    .onHover { isHovering = $0 }
    .pointingHandCursor()
    .accessibilityLabel(title)
    .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
  }
}
