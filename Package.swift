// swift-tools-version: 6.4

import PackageDescription

let package = Package(
  name: "Git", platforms: [.macOS(.v14), .iOS(.v17)],
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

#if os(Windows) || os(Linux)
/// Another v57 repository: GitHub's main branch, or the checkout next to this one with `V57_LOCAL=1`.
func v57(_ name: String) -> Package.Dependency {
  Context.environment["V57_LOCAL"] == nil
    ? .package(url: "https://github.com/v57/\(name).git", branch: "main") : .package(path: "../\(name)")
}
// Off Apple platforms CryptoKit and os are v57/SwiftUI's stand-ins, and the GitHub token is kept by VaultKit's
// keychain (the Windows Credential Manager).
package.dependencies += [v57("SwiftUI"), v57("Vault")]
for target in package.targets {
  switch target.name {
  case "GitHubKit":
    target.dependencies += [
      .product(name: "CryptoKit", package: "SwiftUI"), .product(name: "VaultKit", package: "Vault"),
    ]
  case "GitKit":
    target.dependencies += [.product(name: "os", package: "SwiftUI")]
  default: break
  }
}
#endif
