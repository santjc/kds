import Foundation
import KDSCore

struct KillCandidate: Identifiable, Hashable {
  let pid: Int32
  let processName: String
  let projectName: String?
  let ports: [UInt16]

  var id: Int32 { pid }
}

@MainActor
final class PortStore: ObservableObject {
  @Published private(set) var endpoints: [DisplayEndpoint] = []
  @Published private(set) var isScanning = false
  @Published private(set) var errorMessage: String?
  @Published private(set) var actionErrorMessage: String?
  @Published private(set) var survivorPIDs: Set<Int32> = []

  private let source: any PortSource
  private let inspector: any ProcessInspecting
  private let terminator: any ProcessTerminating
  private let classifier: ProcessClassifier
  private let overrides: EndpointOverrideStore
  private var detailsCache: [Int32: ProcessDetails] = [:]
  private var detailsFingerprints: [Int32: Set<String>] = [:]
  private var survivorPorts: [Int32: Set<UInt16>] = [:]
  private var scanTask: Task<Void, Never>?

  var developmentEndpoints: [DisplayEndpoint] {
    endpoints.filter { $0.classification.category == .development }
  }

  var otherEndpoints: [DisplayEndpoint] {
    endpoints.filter { $0.classification.category != .development }
  }

  var killCandidates: [KillCandidate] {
    Dictionary(grouping: developmentEndpoints, by: { $0.endpoint.pid })
      .map { pid, items in
        KillCandidate(
          pid: pid,
          processName: items[0].endpoint.processName,
          projectName: items.compactMap(\.details.projectName).first,
          ports: items.map(\.endpoint.port).sorted()
        )
      }
      .sorted { ($0.ports.first ?? 0) < ($1.ports.first ?? 0) }
  }

  static func live() -> PortStore {
    PortStore(
      source: LsofPortSource(),
      inspector: SystemProcessInspector(),
      terminator: SystemProcessTerminator(),
      classifier: ProcessClassifier(),
      overrides: EndpointOverrideStore()
    )
  }

  init(
    source: any PortSource,
    inspector: any ProcessInspecting,
    terminator: any ProcessTerminating,
    classifier: ProcessClassifier,
    overrides: EndpointOverrideStore
  ) {
    self.source = source
    self.inspector = inspector
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
      let activePIDs = Set(snapshot.map(\.pid))
      detailsCache = detailsCache.filter { activePIDs.contains($0.key) }
      detailsFingerprints = detailsFingerprints.filter { activePIDs.contains($0.key) }

      let currentFingerprints = Dictionary(grouping: snapshot, by: \.pid)
        .mapValues { Set($0.map(\.id)) }
      let changedPIDs = activePIDs.filter {
        detailsFingerprints[$0] != nil && detailsFingerprints[$0] != currentFingerprints[$0]
      }
      for pid in changedPIDs {
        detailsCache[pid] = nil
      }

      let missingPIDs = activePIDs.filter { detailsCache[$0] == nil }
      let inspector = self.inspector
      let inspected = await withTaskGroup(of: (Int32, ProcessDetails).self) { group in
        for pid in missingPIDs {
          group.addTask {
            (pid, await inspector.inspect(pid: pid))
          }
        }

        var result: [Int32: ProcessDetails] = [:]
        for await (pid, details) in group {
          result[pid] = details
        }
        return result
      }
      detailsCache.merge(inspected) { _, new in new }
      detailsFingerprints = currentFingerprints

      endpoints = snapshot.map { endpoint in
        let details =
          detailsCache[endpoint.pid]
          ?? ProcessDetails(
            executablePath: nil,
            workingDirectory: nil,
            projectRoot: nil
          )
        let override = overrides.value(for: details.executablePath)
        return DisplayEndpoint(
          endpoint: endpoint,
          details: details,
          classification: classifier.classify(
            endpoint: endpoint,
            details: details,
            override: override
          )
        )
      }.sorted(by: Self.sortEndpoints)

      survivorPIDs = Set(
        snapshot.compactMap { endpoint in
          survivorPorts[endpoint.pid]?.contains(endpoint.port) == true ? endpoint.pid : nil
        })
      survivorPorts = survivorPorts.filter { survivorPIDs.contains($0.key) }
      errorMessage = nil
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  func terminate(_ item: DisplayEndpoint, force: Bool = false) async {
    actionErrorMessage = nil
    do {
      let current = try await source.snapshot()
      guard current.contains(where: { $0.id == item.endpoint.id }) else {
        actionErrorMessage = "The process is no longer listening on this port."
        await refresh()
        return
      }

      let result = await terminator.terminate(
        pid: item.endpoint.pid,
        signal: force ? .force : .graceful
      )
      handle(result, processName: item.endpoint.processName)
      try? await Task.sleep(for: .milliseconds(400))
      await refresh()
    } catch {
      actionErrorMessage = error.localizedDescription
    }
  }

  func terminateAll() async {
    actionErrorMessage = nil
    let candidates = killCandidates
    let candidatePIDs = Set(candidates.map(\.pid))
    let candidatePorts = Dictionary(
      uniqueKeysWithValues: candidates.map {
        ($0.pid, Set($0.ports))
      })

    do {
      let current = try await source.snapshot()
      let validatedPIDs = Set(
        current.filter {
          candidatePorts[$0.pid]?.contains($0.port) == true && $0.ownerUID == getuid()
        }.map(\.pid))

      for pid in validatedPIDs {
        let result = await terminator.terminate(pid: pid, signal: .graceful)
        handle(result, processName: candidates.first { $0.pid == pid }?.processName ?? "PID \(pid)")
      }

      try? await Task.sleep(for: .seconds(2))
      survivorPorts = candidatePorts
      survivorPIDs = candidatePIDs
      await refresh()
    } catch {
      actionErrorMessage = error.localizedDescription
    }
  }

  func forceKillSurvivors() async {
    actionErrorMessage = nil
    let pids = survivorPIDs
    guard !pids.isEmpty else { return }

    do {
      let current = try await source.snapshot()
      let validatedPIDs = Set(
        current.filter {
          survivorPorts[$0.pid]?.contains($0.port) == true && $0.ownerUID == getuid()
        }.map(\.pid))
      for pid in validatedPIDs {
        let result = await terminator.terminate(pid: pid, signal: .force)
        handle(result, processName: "PID \(pid)")
      }
      survivorPIDs = []
      survivorPorts = [:]
      try? await Task.sleep(for: .milliseconds(400))
      await refresh()
    } catch {
      actionErrorMessage = error.localizedDescription
    }
  }

  func setOverride(_ value: ProcessOverride?, for item: DisplayEndpoint) {
    guard let path = item.details.executablePath else { return }
    overrides.set(value, for: path)
    endpoints = endpoints.map { endpoint in
      guard endpoint.endpoint.pid == item.endpoint.pid else { return endpoint }
      return DisplayEndpoint(
        endpoint: endpoint.endpoint,
        details: endpoint.details,
        classification: classifier.classify(
          endpoint: endpoint.endpoint,
          details: endpoint.details,
          override: value
        )
      )
    }.sorted(by: Self.sortEndpoints)
  }

  func currentOverride(for item: DisplayEndpoint) -> ProcessOverride? {
    overrides.value(for: item.details.executablePath)
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

  private static func sortEndpoints(_ lhs: DisplayEndpoint, _ rhs: DisplayEndpoint) -> Bool {
    let order: [EndpointCategory: Int] = [.development: 0, .other: 1, .protected: 2]
    let left = order[lhs.classification.category] ?? 3
    let right = order[rhs.classification.category] ?? 3
    if left != right { return left < right }
    if lhs.endpoint.port != rhs.endpoint.port { return lhs.endpoint.port < rhs.endpoint.port }
    return lhs.endpoint.pid < rhs.endpoint.pid
  }
}
