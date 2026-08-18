import Foundation
import KDSCore

@MainActor
final class MemoryStore: ObservableObject {
  /// Anything smaller than this is noise on a machine with gigabytes of RAM.
  private static let minimumResidentBytes: UInt64 = 20 * 1024 * 1024
  private static let displayLimit = 40

  @Published private(set) var processes: [DisplayMemoryProcess] = []
  @Published private(set) var isScanning = false
  @Published private(set) var errorMessage: String?
  @Published private(set) var actionErrorMessage: String?

  private let source: any ProcessMemorySource
  private let terminator: any ProcessTerminating
  private let classifier: MemoryClassifier
  private let overrides: EndpointOverrideStore
  private var scanTask: Task<Void, Never>?

  var developmentProcesses: [DisplayMemoryProcess] {
    processes.filter { $0.classification.category == .development }
  }

  var otherProcesses: [DisplayMemoryProcess] {
    processes.filter { $0.classification.category != .development }
  }

  var totalResidentBytes: UInt64 {
    processes.reduce(0) { $0 + $1.process.residentBytes }
  }

  static func live() -> MemoryStore {
    MemoryStore(
      source: PSProcessMemorySource(),
      terminator: SystemProcessTerminator(),
      classifier: MemoryClassifier(),
      overrides: EndpointOverrideStore()
    )
  }

  init(
    source: any ProcessMemorySource,
    terminator: any ProcessTerminating,
    classifier: MemoryClassifier,
    overrides: EndpointOverrideStore
  ) {
    self.source = source
    self.terminator = terminator
    self.classifier = classifier
    self.overrides = overrides
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
    guard !isScanning else { return }
    isScanning = true
    defer { isScanning = false }

    do {
      let snapshot = try await source.snapshot()
      guard !Task.isCancelled else { return }

      processes =
        snapshot
        .filter { $0.residentBytes >= Self.minimumResidentBytes }
        .prefix(Self.displayLimit)
        .map { process in
          DisplayMemoryProcess(
            process: process,
            classification: classifier.classify(
              process: process,
              override: overrides.value(for: process.commandPath)
            )
          )
        }
      errorMessage = nil
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  func terminate(_ item: DisplayMemoryProcess, force: Bool = false) async {
    actionErrorMessage = nil
    guard item.classification.category != .protected else { return }

    do {
      // Re-validate against a fresh snapshot. Matching the command path as well as the PID
      // is what guards against signalling an unrelated process that reused the PID.
      let current = try await source.snapshot()
      guard
        current.contains(where: {
          $0.pid == item.process.pid && $0.commandPath == item.process.commandPath
            && $0.ownerUID == getuid()
        })
      else {
        actionErrorMessage = "\(item.process.processName) is no longer running."
        await refresh()
        return
      }

      let result = await terminator.terminate(
        pid: item.process.pid,
        signal: force ? .force : .graceful
      )
      handle(result, processName: item.process.processName)
      try? await Task.sleep(for: .milliseconds(400))
      await refresh()
    } catch {
      actionErrorMessage = error.localizedDescription
    }
  }

  func setOverride(_ value: ProcessOverride?, for item: DisplayMemoryProcess) {
    overrides.set(value, for: item.process.commandPath)
    processes = processes.map { entry in
      guard entry.process.pid == item.process.pid else { return entry }
      return DisplayMemoryProcess(
        process: entry.process,
        classification: classifier.classify(process: entry.process, override: value)
      )
    }
  }

  func currentOverride(for item: DisplayMemoryProcess) -> ProcessOverride? {
    overrides.value(for: item.process.commandPath)
  }

  private func handle(_ result: TerminationResult, processName: String) {
    switch result {
    case .success, .notFound:
      break
    case .permissionDenied:
      actionErrorMessage = "KDS does not have permission to terminate \(processName)."
    case .failed(let code):
      actionErrorMessage = "Could not terminate \(processName) (error \(code))."
    }
  }
}
