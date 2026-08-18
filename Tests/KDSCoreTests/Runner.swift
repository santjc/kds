import Darwin
import Foundation

@main
struct TestRunner {
  static func main() async {
    let tests =
      lsofParserTests + processClassifierTests + projectResolverTests + integrationTests
      + psProcessParserTests + memoryClassifierTests + systemMetricsTests
    var failures = 0

    for test in tests {
      do {
        try await test.body()
        print("✓ \(test.name)")
      } catch {
        failures += 1
        print("✗ \(test.name): \(error)")
      }
    }

    print("\n\(tests.count - failures)/\(tests.count) tests passed")
    if failures > 0 {
      exit(EXIT_FAILURE)
    }
  }
}
