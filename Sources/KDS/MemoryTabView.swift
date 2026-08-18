import AppKit
import KDSCore
import SwiftUI

struct MemoryTabView: View {
  @EnvironmentObject private var store: MemoryStore
  @State private var showsOtherProcesses = false

  var body: some View {
    if store.processes.isEmpty && !store.isScanning {
      EmptyStateView(
        systemName: "memorychip",
        title: "Nothing to reclaim",
        message: "No process is holding a significant amount of memory."
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

          sectionTitle("Development")
          if store.developmentProcesses.isEmpty {
            Text("No development processes using memory")
              .font(.callout)
              .foregroundStyle(.secondary)
              .padding(.horizontal, 4)
          } else {
            MemoryList(items: store.developmentProcesses)
          }

          if !store.otherProcesses.isEmpty {
            DisclosureHeader(
              title: "Other Processes",
              count: store.otherProcesses.count,
              isExpanded: $showsOtherProcesses
            )

            if showsOtherProcesses {
              MemoryList(items: store.otherProcesses)
            }
          }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
      }
    }
  }
}

struct MemoryFooterSummary: View {
  @EnvironmentObject private var store: MemoryStore

  var body: some View {
    Text(summary)
      .font(.caption)
      .foregroundStyle(.secondary)
  }

  private var summary: String {
    guard !store.processes.isEmpty else { return "No processes listed" }
    let formatter = ByteCountFormatter()
    formatter.allowedUnits = [.useGB, .useMB]
    formatter.countStyle = .memory
    let total = formatter.string(fromByteCount: Int64(store.totalResidentBytes))
    return "\(store.processes.count) processes · \(total)"
  }
}

private struct MemoryList: View {
  let items: [DisplayMemoryProcess]

  var body: some View {
    VStack(spacing: 0) {
      ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
        MemoryRow(item: item)
        if index < items.count - 1 {
          Divider()
            .padding(.leading, MenuMetrics.sizeWidth + 14)
            .opacity(0.55)
        }
      }
    }
  }
}

private struct MemoryRow: View {
  @EnvironmentObject private var store: MemoryStore
  let item: DisplayMemoryProcess
  @State private var confirmsTermination = false
  @State private var isHovering = false

  var body: some View {
    HStack(spacing: 8) {
      Text(sizeLabel)
        .font(.system(.callout, design: .monospaced).weight(.semibold))
        .frame(width: MenuMetrics.sizeWidth, alignment: .leading)

      VStack(alignment: .leading, spacing: 2) {
        Text(item.process.processName)
          .lineLimit(1)
          .truncationMode(.middle)
        Text(subtitle)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }
      .frame(maxWidth: .infinity, alignment: .leading)

      Menu {
        Button("Copy Path") { copyPath() }
        Divider()
        classificationActions
      } label: {
        IconControlLabel(systemName: "ellipsis", title: "More actions")
      }
      .menuStyle(.borderlessButton)
      .menuIndicator(.hidden)
      .fixedSize()
      .help(item.process.commandPath)
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
      .disabled(item.classification.category == .protected)
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
      "Quit \(item.process.processName)?",
      isPresented: $confirmsTermination,
      titleVisibility: .visible
    ) {
      Button("Terminate", role: .destructive) {
        Task { await store.terminate(item) }
      }
    } message: {
      Text(
        "\(item.classification.reason). Unsaved work in this process will be lost."
      )
    }
  }

  private var sizeLabel: String {
    let formatter = ByteCountFormatter()
    formatter.allowedUnits = item.process.residentBytes >= 1_073_741_824 ? [.useGB] : [.useMB]
    formatter.countStyle = .memory
    formatter.includesUnit = true
    return formatter.string(fromByteCount: Int64(item.process.residentBytes))
  }

  private var subtitle: String {
    let cpu = String(format: "%.0f%% CPU", item.process.cpuPercent)
    return "PID \(item.process.pid) · \(cpu) · \(item.classification.reason)"
  }

  @ViewBuilder
  private var classificationActions: some View {
    if store.currentOverride(for: item) != nil {
      Button("Use Automatic Classification") { store.setOverride(nil, for: item) }
    }
    if item.classification.category == .development {
      Button("Protect from Termination") { store.setOverride(.protect, for: item) }
    } else if item.classification.category == .other {
      Button("Treat as Development Process") { store.setOverride(.include, for: item) }
    }
  }

  private func copyPath() {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(item.process.commandPath, forType: .string)
  }
}
