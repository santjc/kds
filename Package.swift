// swift-tools-version: 6.0

import PackageDescription

let package = Package(
  name: "KDS",
  platforms: [.macOS(.v13)],
  products: [
    .library(name: "KDSCore", targets: ["KDSCore"]),
    .executable(name: "KDS", targets: ["KDS"]),
  ],
  targets: [
    .target(name: "KDSCore"),
    .executableTarget(name: "KDS", dependencies: ["KDSCore"]),
    .executableTarget(
      name: "KDSCoreTests",
      dependencies: ["KDSCore"],
      path: "Tests/KDSCoreTests"
    ),
  ]
)
