import Foundation
import IOKit

/// Machine-wide GPU utilisation, read from the accelerator's IORegistry performance
/// counters. There is no public per-process equivalent on macOS, so this is the only
/// GPU figure KDS can report honestly.
public enum GPUUtilization {
  /// Provider classes differ by silicon: Intel and AMD publish `IOAccelerator`,
  /// Apple Silicon publishes `IOGPU`.
  private static let providerClasses = ["IOAccelerator", "IOGPU"]

  /// Vendors disagree on the counter name; the first one present wins.
  private static let utilizationKeys = [
    "Device Utilization %",
    "GPU Activity(%)",
    "Renderer Utilization %",
  ]

  /// The busiest accelerator, or nil when no counter is exposed.
  public static func currentPercent() -> Double? {
    var highest: Double?
    for providerClass in providerClasses {
      guard let matching = IOServiceMatching(providerClass) else { continue }
      var iterator: io_iterator_t = 0
      guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS
      else { continue }
      defer { IOObjectRelease(iterator) }

      while case let service = IOIteratorNext(iterator), service != 0 {
        defer { IOObjectRelease(service) }
        guard let percent = utilization(of: service) else { continue }
        highest = max(highest ?? 0, percent)
      }
    }
    return highest
  }

  private static func utilization(of service: io_registry_entry_t) -> Double? {
    let property = IORegistryEntryCreateCFProperty(
      service, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0)
    guard let statistics = property?.takeRetainedValue() as? [String: Any] else { return nil }

    for key in utilizationKeys {
      guard let value = statistics[key] as? NSNumber else { continue }
      return min(100, max(0, value.doubleValue))
    }
    return nil
  }
}
