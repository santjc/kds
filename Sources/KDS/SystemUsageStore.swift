import Foundation
import KDSCore

@MainActor
final class SystemUsageStore: ObservableObject {
  @Published private(set) var usage = SystemUsage()

  private let sampler: any SystemMetricsSampling
  private var sampleTask: Task<Void, Never>?

  init(sampler: any SystemMetricsSampling = HostSystemMetricsSampler()) {
    self.sampler = sampler
  }

  func start() {
    guard sampleTask == nil else { return }
    sampleTask = Task { [weak self] in
      // CPU is a delta between two readings, so prime one before the first display value.
      if let self {
        _ = await self.sampler.sample()
        try? await Task.sleep(for: .milliseconds(400))
      }

      while !Task.isCancelled {
        guard let self else { return }
        let sample = await self.sampler.sample()
        guard !Task.isCancelled else { return }
        self.usage = sample
        do {
          try await Task.sleep(for: .seconds(1))
        } catch {
          break
        }
      }
    }
  }

  func stop() {
    sampleTask?.cancel()
    sampleTask = nil
  }
}
