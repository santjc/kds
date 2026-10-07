import Foundation
import KDSCore

@MainActor
final class BackgroundStore: ObservableObject {
  @Published private(set) var processes: [BackgroundProcess] = []
  /// Summed over each row's `usagePIDs`, keyed by row id.
  @Published private(set) var usage: [String: ProcessUsage] = [:]
  /// Project directory names for agent sessions, so three Claude sessions are tellable apart.
  @Published private(set) var projectNames: [String: String] = [:]
  @Published private(set) var actionErrorMessage: String?

  private let table: any ProcessTableSource
  private let classifier: BackgroundProcessClassifier
  private let inspector: any ProcessInspecting
  private let terminator: any ProcessTerminating
  private let usageSampler: any ProcessUsageSampling
  private var scanTask: Task<Void, Never>?
  private var isRefreshing = false
  /// Start time of every PID in the scan the rows were built from.
  private var scannedStarts: [Int32: Date] = [:]

  var killAllCandidates: [BackgroundProcess] {
    processes.filter(\.isKillAllEligible)
  }

  static func live() -> BackgroundStore {
    BackgroundStore(
      table: SysctlProcessTable(),
      classifier: BackgroundProcessClassifier(),
      inspector: SystemProcessInspector(),
      terminator: SystemProcessTerminator(),
      usageSampler: RusageProcessUsageSampler()
    )
  }

  init(
    table: any ProcessTableSource,
    classifier: BackgroundProcessClassifier,
    inspector: any ProcessInspecting,
    terminator: any ProcessTerminating,
    usageSampler: any ProcessUsageSampling
  ) {
    self.table = table
    self.classifier = classifier
    self.inspector = inspector
    self.terminator = terminator
    self.usageSampler = usageSampler
  }

  func startVisibleScanning() {
    guard scanTask == nil else { return }
    scanTask = Task { [weak self] in
      while !Task.isCancelled {
        await self?.refresh()
        do {
          try await Task.sleep(for: .seconds(2))
        } catch {
          break
        }
      }
    }
  }

  func stopVisibleScanning() {
    scanTask?.cancel()
    scanTask = nil
  }

  func refresh() async {
    guard !isRefreshing else { return }
    isRefreshing = true
    defer { isRefreshing = false }

    let snapshot = await table.snapshot()
    guard !Task.isCancelled else { return }
    let rows = classifier.classify(snapshot)

    let perPID = await usageSampler.sample(pids: rows.flatMap(\.usagePIDs))
    var totals: [String: ProcessUsage] = [:]
    for row in rows {
      let parts = row.usagePIDs.compactMap { perPID[$0] }
      guard !parts.isEmpty else { continue }
      totals[row.id] = ProcessUsage(
        cpuPercent: parts.map(\.cpuPercent).reduce(0, +),
        residentBytes: parts.map(\.residentBytes).reduce(0, +),
        memoryPercent: parts.map(\.memoryPercent).reduce(0, +)
      )
    }

    let liveIDs = Set(rows.map(\.id))
    var names = projectNames.filter { liveIDs.contains($0.key) }
    let inspector = self.inspector
    for row in rows where row.kind == .agentSession && names[row.id] == nil {
      // Only a real project root: daemons run from scratch directories with opaque names.
      let root = await inspector.inspect(pid: row.pid).projectRoot
      names[row.id] = root.map { URL(fileURLWithPath: $0).lastPathComponent } ?? ""
    }

    processes = rows
    scannedStarts = Dictionary(
      snapshot.map { ($0.pid, $0.startDate) }, uniquingKeysWith: { first, _ in first })
    usage = totals
    projectNames = names
  }

  func terminate(_ row: BackgroundProcess) async {
    actionErrorMessage = nil
    await signal([row])
    try? await Task.sleep(for: .milliseconds(400))
    await refresh()
  }

  func terminateAll() async {
    actionErrorMessage = nil
    await signal(killAllCandidates)
    try? await Task.sleep(for: .seconds(1))
    await refresh()
  }

  /// Re-reads the table and signals only processes whose PID still has the start time
  /// the row was built from, so a recycled PID is never hit.
  private func signal(_ rows: [BackgroundProcess]) async {
    let current = await table.snapshot()
    let startByPID = Dictionary(
      current.map { ($0.pid, $0.startDate) }, uniquingKeysWith: { first, _ in first })

    for row in rows {
      guard startByPID[row.pid] == row.startDate else {
        actionErrorMessage = "\(row.name) is no longer running."
        continue
      }
      // Workers before their launcher, so `npm exec` cannot respawn or orphan `node`.
      for pid in row.terminationPIDs.filter({ $0 != row.pid }) + [row.pid] {
        guard let expected = scannedStarts[pid], startByPID[pid] == expected else { continue }
        switch await terminator.terminate(pid: pid, signal: .graceful) {
        case .success, .notFound:
          break
        case .permissionDenied:
          actionErrorMessage = "KDS does not have permission to terminate \(row.name)."
        case .failed(let code):
          actionErrorMessage = "Could not terminate \(row.name) (error \(code))."
        }
      }
    }
  }
}
