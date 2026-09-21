import AppKit
import KDSCore
import SwiftUI

struct ServerTableView: View {
  @EnvironmentObject private var store: PortStore
  @EnvironmentObject private var launchAtLogin: LaunchAtLoginController
  @State private var showsOtherListeners = false
  @State private var showsForceConfirmation = false

  var body: some View {
    Group {
      if store.endpoints.isEmpty && !store.isScanning {
        EmptyStateView(
          systemName: "checkmark.circle",
          title: "No listeners found",
          message: "Open a dev server and refresh."
        )
      } else {
        SelfSizingScrollView {
          VStack(alignment: .leading, spacing: 8) {
            if let message = store.errorMessage {
              ErrorBanner(message: message)
            }
            if let message = store.actionErrorMessage {
              ErrorBanner(message: message)
            }
            if let message = launchAtLogin.errorMessage {
              ErrorBanner(message: message)
            }

            if !store.survivorPIDs.isEmpty {
              HStack {
                Text("\(store.survivorPIDs.count) process(es) ignored SIGTERM")
                  .font(.caption)
                Spacer()
                Button("Force Kill") { showsForceConfirmation = true }
                  .buttonStyle(.borderless)
                  .pointingHandCursor()
              }
              .padding(8)
              .background(.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
            }

            ColumnHeader()

            if store.developmentEndpoints.isEmpty {
              Text("No development servers detected")
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)
            } else {
              EndpointList(endpoints: store.developmentEndpoints)
            }

            if !store.otherEndpoints.isEmpty {
              DisclosureHeader(
                title: "Other Listeners",
                count: store.otherEndpoints.count,
                isExpanded: $showsOtherListeners
              )

              if showsOtherListeners {
                EndpointList(endpoints: store.otherEndpoints)
              }
            }
          }
          .padding(.horizontal, 10)
          .padding(.vertical, 8)
        }
      }
    }
    .confirmationDialog(
      "Force kill remaining processes?",
      isPresented: $showsForceConfirmation,
      titleVisibility: .visible
    ) {
      Button("Force Kill", role: .destructive) {
        Task { await store.forceKillSurvivors() }
      }
    } message: {
      Text("This immediately stops the remaining processes without cleanup.")
    }
  }
}

struct ServerFooterActions: View {
  @EnvironmentObject private var store: PortStore
  @State private var showsKillPreview = false

  var body: some View {
    Button("Kill All") { showsKillPreview = true }
      .buttonStyle(.borderedProminent)
      .controlSize(.small)
      .tint(.red)
      .disabled(store.killCandidates.isEmpty)
      .pointingHandCursor()
      .sheet(isPresented: $showsKillPreview) {
        KillPreviewView(candidates: store.killCandidates) {
          showsKillPreview = false
          Task { await store.terminateAll() }
        }
      }
  }
}

struct EmptyStateView: View {
  let systemName: String
  let title: String
  let message: String

  var body: some View {
    VStack(spacing: 8) {
      Image(systemName: systemName)
        .font(.largeTitle)
        .foregroundStyle(.secondary)
      Text(title).font(.headline)
      Text(message)
        .font(.callout)
        .foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity)
    .padding(.vertical, 28)
  }
}

/// Column titles for the table below. Widths come from `MenuMetrics` so the header
/// and every row stay on the same grid.
private struct ColumnHeader: View {
  var body: some View {
    HStack(spacing: 8) {
      Text("PORT")
        .frame(width: MenuMetrics.portWidth, alignment: .leading)
      Text("NAME")
        .frame(maxWidth: .infinity, alignment: .leading)
      Text("CPU")
        .frame(width: MenuMetrics.metricWidth, alignment: .trailing)
      Text("RAM")
        .frame(width: MenuMetrics.metricWidth, alignment: .trailing)
      // Keeps the titles clear of the row's action controls.
      Color.clear.frame(width: MenuMetrics.controlSize * 2, height: 1)
    }
    .font(.caption2.weight(.semibold))
    .tracking(0.5)
    .foregroundStyle(.tertiary)
    .padding(.horizontal, 6)
    .accessibilityHidden(true)
  }
}

private struct EndpointList: View {
  let endpoints: [DisplayEndpoint]

  var body: some View {
    VStack(spacing: 0) {
      ForEach(Array(endpoints.enumerated()), id: \.element.id) { index, endpoint in
        EndpointRow(item: endpoint)
        if index < endpoints.count - 1 {
          Divider()
            .padding(.leading, MenuMetrics.portWidth + 14)
            .opacity(0.55)
        }
      }
    }
  }
}

/// One metric cell. A missing value reads as an em dash rather than a misleading zero.
private struct MetricCell: View {
  let percent: Double?
  let label: String

  var body: some View {
    Text(UsageGaugesView.percentLabel(percent))
      .font(.system(.caption, design: .monospaced))
      .foregroundStyle(tint)
      .frame(width: MenuMetrics.metricWidth, alignment: .trailing)
      .accessibilityLabel(label)
      .accessibilityValue(UsageGaugesView.percentLabel(percent))
  }

  private var tint: AnyShapeStyle {
    guard let percent else { return AnyShapeStyle(.tertiary) }
    switch percent {
    case ..<25: return AnyShapeStyle(.secondary)
    case ..<75: return AnyShapeStyle(Color.orange)
    default: return AnyShapeStyle(Color.red)
    }
  }
}

private struct EndpointRow: View {
  @EnvironmentObject private var store: PortStore
  let item: DisplayEndpoint
  @State private var confirmsTermination = false
  @State private var isHovering = false

  var body: some View {
    HStack(spacing: 8) {
      Text(verbatim: ":\(item.endpoint.port)")
        .font(.system(.callout, design: .monospaced).weight(.semibold))
        .frame(width: MenuMetrics.portWidth, alignment: .leading)

      VStack(alignment: .leading, spacing: 2) {
        Text(item.details.projectName ?? item.endpoint.processName)
          .lineLimit(1)
        Text(subtitle)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }
      .frame(maxWidth: .infinity, alignment: .leading)

      // No GPU column: macOS exposes no public per-process GPU counter, and a column
      // of em dashes is only noise. The panel gauge carries the machine-wide figure.
      MetricCell(percent: usage?.cpuPercent, label: "CPU")
      MetricCell(percent: usage?.memoryPercent, label: "RAM")

      Menu {
        Button("Open localhost") { openURL() }
        Button("Copy URL") { copyURL() }
        Divider()
        classificationActions
      } label: {
        IconControlLabel(systemName: "ellipsis", title: "More actions")
      }
      .menuStyle(.borderlessButton)
      .menuIndicator(.hidden)
      .fixedSize()
      .help("More actions")
      .interactiveIconControl()

      Button(role: .destructive) {
        if item.classification.category == .development {
          Task { await store.terminate(item) }
        } else {
          confirmsTermination = true
        }
      } label: {
        IconControlLabel(systemName: "xmark", title: "Terminate", color: .red)
      }
      .buttonStyle(.borderless)
      .disabled(item.endpoint.pid == getpid())
      .help("Terminate")
      .interactiveIconControl()
    }
    .padding(.horizontal, 6)
    .frame(minHeight: MenuMetrics.rowHeight)
    .background(
      isHovering ? Color.primary.opacity(0.055) : Color.clear,
      in: RoundedRectangle(cornerRadius: 6)
    )
    .contentShape(Rectangle())
    .onHover { isHovering = $0 }
    .confirmationDialog(
      "Terminate \(item.endpoint.processName)?",
      isPresented: $confirmsTermination,
      titleVisibility: .visible
    ) {
      Button("Terminate", role: .destructive) {
        Task { await store.terminate(item) }
      }
    } message: {
      Text("This listener is excluded from Kill All: \(item.classification.reason).")
    }
  }

  private var usage: ProcessUsage? {
    store.usage[item.endpoint.pid]
  }

  private var subtitle: String {
    "\(item.endpoint.processName) · PID \(item.endpoint.pid)"
  }

  @ViewBuilder
  private var classificationActions: some View {
    if item.details.executablePath != nil {
      if store.currentOverride(for: item) != nil {
        Button("Use Automatic Classification") { store.setOverride(nil, for: item) }
      }
      if item.classification.category == .development {
        Button("Protect from Kill All") { store.setOverride(.protect, for: item) }
      } else if item.classification.category == .other {
        Button("Include in Kill All") { store.setOverride(.include, for: item) }
      }
    }
  }

  private func openURL() {
    guard let url = URL(string: "http://localhost:\(item.endpoint.port)") else { return }
    NSWorkspace.shared.open(url)
  }

  private func copyURL() {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString("http://localhost:\(item.endpoint.port)", forType: .string)
  }
}

private struct KillPreviewView: View {
  @Environment(\.dismiss) private var dismiss
  let candidates: [KillCandidate]
  let confirm: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("Kill all dev servers?").font(.headline)
      Text("KDS will send SIGTERM to these processes:")
        .font(.callout)
        .foregroundStyle(.secondary)

      ScrollView {
        VStack(spacing: 0) {
          ForEach(Array(candidates.enumerated()), id: \.element.id) { index, candidate in
            HStack {
              VStack(alignment: .leading) {
                Text(candidate.projectName ?? candidate.processName)
                Text("PID \(candidate.pid)")
                  .font(.caption)
                  .foregroundStyle(.secondary)
              }
              Spacer()
              Text(verbatim: candidate.ports.map { ":\($0)" }.joined(separator: ", "))
                .font(.system(.caption, design: .monospaced))
            }
            .padding(8)
            .frame(minHeight: MenuMetrics.rowHeight)

            if index < candidates.count - 1 {
              Divider()
            }
          }
        }
      }

      HStack {
        Spacer()
        Button("Cancel") { dismiss() }
          .pointingHandCursor()
        Button("Terminate All", role: .destructive, action: confirm)
          .buttonStyle(.borderedProminent)
          .tint(.red)
          .pointingHandCursor()
      }
    }
    .padding(20)
    .frame(width: 380, height: 380)
  }
}
