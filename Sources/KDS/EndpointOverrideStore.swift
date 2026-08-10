import Foundation
import KDSCore

@MainActor
final class EndpointOverrideStore {
  private let defaults: UserDefaults
  private let key = "processOverrides"
  private(set) var values: [String: ProcessOverride]

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    if let data = defaults.data(forKey: key),
      let decoded = try? JSONDecoder().decode([String: ProcessOverride].self, from: data)
    {
      values = decoded
    } else {
      values = [:]
    }
  }

  func value(for executablePath: String?) -> ProcessOverride? {
    executablePath.flatMap { values[$0] }
  }

  func set(_ value: ProcessOverride?, for executablePath: String) {
    values[executablePath] = value
    defaults.set(try? JSONEncoder().encode(values), forKey: key)
  }
}
