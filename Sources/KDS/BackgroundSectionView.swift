import KDSCore
import SwiftUI

/// Headless browsers, MCP servers, agent sessions and their leftovers. Same grid as the
/// server table, with age in the leading column instead of a port.
struct BackgroundSection: View {
  @EnvironmentObject private var background: BackgroundStore
  @AppStorage("showsBackgroundProcesses") private var isExpanded = true
  @State private var confirmsCleanUp = false

  var body: some View {
    if !background.processes.isEmpty {
      VStack(alignment: .leading, spacing: 8) {
        HStack(spacing: 8) {
          DisclosureHeader(
            title: "Background",
            count: background.processes.count,
            isExpanded: $isExpanded
          )
          if !background.killAllCandidates.isEmpty {
            Button("Clean Up \(background.killAllCandidates.count)") { confirmsCleanUp = true }
              .buttonStyle(.bordered)
              .controlSize(.small)
              .tint(.red)
              .pointingHandCursor()
              .help("Terminate background processes no live agent is using")
          }
        }

        if let message = background.actionErrorMessage {
          ErrorBanner(message: message)
        }

        if isExpanded {
          ColumnHeader(leading: "AGE")
          VStack(spacing: 0) {
            ForEach(Array(background.processes.enumerated()), id: \.element.id) { index, row in
              BackgroundRow(row: row)
              if index < background.processes.count - 1 {
                Divider()
                  .padding(.leading, MenuMetrics.portWidth + 14)
                  .opacity(0.55)
              }
            }
          }
        }
      }
      .confirmationDialog(
        "Clean up \(background.killAllCandidates.count) background processes?",
        isPresented: $confirmsCleanUp,
        titleVisibility: .visible
      ) {
        Button("Terminate", role: .destructive) {
          Task { await background.terminateAll() }
        }
      } message: {
        Text(cleanUpMessage)
      }
    }
  }

  private var cleanUpMessage: String {
    let names = background.killAllCandidates.map(\.name)
    let listed = names.prefix(6).joined(separator: ", ")
    let more = names.count > 6 ? " and \(names.count - 6) more" : ""
    return "KDS will send SIGTERM to \(listed)\(more). Agent sessions and anything they are "
      + "still using are left alone."
  }
}

private struct BackgroundRow: View {
  @EnvironmentObject private var background: BackgroundStore
  let row: BackgroundProcess
  @State private var confirmsTermination = false
  @State private var isHovering = false

  var body: some View {
    HStack(spacing: 8) {
      // TimelineView keeps "<1m" honest between scans without re-rendering the table.
      TimelineView(.periodic(from: .now, by: 30)) { context in
        Text(ElapsedTime.short(since: row.startDate, now: context.date))
          .font(.system(.callout, design: .monospaced).weight(.semibold))
          .foregroundStyle(ageStyle(now: context.date))
          .frame(width: MenuMetrics.portWidth, alignment: .leading)
          .help(
            "\(ElapsedTime.spoken(since: row.startDate, now: context.date)) · "
              + row.startDate.formatted(date: .abbreviated, time: .shortened))
          .accessibilityLabel(ElapsedTime.spoken(since: row.startDate, now: context.date))
      }

      VStack(alignment: .leading, spacing: 2) {
        Text(title)
          .lineLimit(1)
        Text(subtitle)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }
      .frame(maxWidth: .infinity, alignment: .leading)

      MetricCell(percent: usage?.cpuPercent, label: "CPU")
      MetricCell(percent: usage?.memoryPercent, label: "RAM")

      // Holds the slot the server rows give their More menu, so the columns line up.
      Color.clear.frame(width: MenuMetrics.controlSize, height: 1)

      Button(role: .destructive) {
        if needsConfirmation {
          confirmsTermination = true
        } else {
          Task { await background.terminate(row) }
        }
      } label: {
        IconControlLabel(systemName: "xmark", title: "Terminate", color: .red)
      }
      .buttonStyle(.borderless)
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
      "Terminate \(title)?",
      isPresented: $confirmsTermination,
      titleVisibility: .visible
    ) {
      Button("Terminate", role: .destructive) {
        Task { await background.terminate(row) }
      }
    } message: {
      Text(confirmationMessage)
    }
  }

  private var usage: ProcessUsage? { background.usage[row.id] }

  private var title: String {
    guard row.kind == .agentSession,
      let project = background.projectNames[row.id], !project.isEmpty
    else { return row.name }
    return "\(row.name) · \(project)"
  }

  /// Ownership comes before the PID: when the line truncates, who owns it is the part
  /// that decides whether to kill it.
  private var subtitle: String {
    var parts = [kindLabel]
    if !row.detail.isEmpty, row.kind != .agentLeftover { parts.append(row.detail) }
    switch row.ownership {
    case .agent(let name): parts.append("via \(name)")
    case .detached: parts.append("detached")
    case .attached: break
    }
    parts.append("PID \(row.pid)")
    return parts.joined(separator: " · ")
  }

  private var kindLabel: String {
    switch row.kind {
    case .agentSession: "Agent"
    case .automatedBrowser: "Browser"
    case .agentBrowser: "Browser automation"
    case .mcpServer: "MCP server"
    case .agentLeftover: "Left by \(row.detail)"
    }
  }

  /// Anything older than a day is probably forgotten; tint it so it stands out.
  private func ageStyle(now: Date) -> AnyShapeStyle {
    let isStale = now.timeIntervalSince(row.startDate) > 86_400 && row.isKillAllEligible
    return isStale ? AnyShapeStyle(Color.orange) : AnyShapeStyle(.primary)
  }

  private var needsConfirmation: Bool {
    if row.kind == .agentSession { return true }
    if case .agent = row.ownership { return true }
    return false
  }

  private var confirmationMessage: String {
    switch (row.kind, row.ownership) {
    case (.agentSession, _):
      "This may be the session you are working in. Unsaved agent work is lost."
    case (_, .agent(let name)):
      "\(name) is still using this. Its tools will stop working until it restarts them."
    default:
      "KDS will send SIGTERM to PID \(row.pid)."
    }
  }
}
