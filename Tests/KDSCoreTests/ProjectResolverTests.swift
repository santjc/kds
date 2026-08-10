import Foundation
import KDSCore

let projectResolverTests: [TestCase] = [
  TestCase("finds the nearest project marker") {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let nested = root.appendingPathComponent("Sources/Feature")
    try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
    _ = FileManager.default.createFile(
      atPath: root.appendingPathComponent("Package.swift").path,
      contents: Data()
    )
    defer { try? FileManager.default.removeItem(at: root) }

    try expect(ProjectResolver().projectRoot(startingAt: nested.path) == root.path)
  },
  TestCase("returns nil without project markers") {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    try expect(ProjectResolver().projectRoot(startingAt: root.path) == nil)
  },
]
