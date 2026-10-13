// swift-tools-version: 6.4

import PackageDescription

let package = Package(
  name: "Git", platforms: [.macOS(.v15)],
  products: [
    .library(name: "GitKit", targets: ["GitKit"]),
    .library(name: "GitHubKit", targets: ["GitHubKit"]),
  ],
  targets: [
    .target(name: "GitKit", swiftSettings: [.enableUpcomingFeature("ApproachableConcurrency")], ),
    .target(name: "GitHubKit", swiftSettings: [.enableUpcomingFeature("ApproachableConcurrency")], ),
    .testTarget(
      name: "GitKitTests", dependencies: ["GitKit"],
      swiftSettings: [.enableUpcomingFeature("ApproachableConcurrency")], ),
    .testTarget(
      name: "GitHubKitTests", dependencies: ["GitHubKit"],
      swiftSettings: [.enableUpcomingFeature("ApproachableConcurrency")], ),
  ])
