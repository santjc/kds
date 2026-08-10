import Foundation

struct TestCase: Sendable {
  let name: String
  let body: @Sendable () async throws -> Void

  init(_ name: String, _ body: @escaping @Sendable () async throws -> Void) {
    self.name = name
    self.body = body
  }
}

struct TestFailure: Error, CustomStringConvertible {
  let message: String
  var description: String { message }
}

func expect(
  _ condition: @autoclosure () -> Bool,
  _ message: String = "Expectation failed",
  file: StaticString = #fileID,
  line: UInt = #line
) throws {
  guard condition() else {
    throw TestFailure(message: "\(file):\(line): \(message)")
  }
}
