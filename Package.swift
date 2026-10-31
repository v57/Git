// swift-tools-version: 6.4

import PackageDescription

/// Another v57 repository: GitHub's main branch, or the checkout next to this one with `V57_LOCAL=1` (in Xcode, the
/// apps' -Local workspaces).
func v57(_ name: String) -> Package.Dependency {
  Context.environment["V57_LOCAL"] == nil
    ? .package(url: "https://github.com/v57/\(name).git", branch: "main") : .package(path: "../\(name)")
}

/// The libraries other repositories use (GitHubKit and GitHubUI: Markdown, Dev), hence macOS 14 / iOS 17. The apps are
/// the package in App/ (App/Package.swift), so the libraries carry none of their dependencies but GitHubUI's
/// ComponentKit.
let package = Package(
  name: "Git", platforms: [.macOS(.v14), .iOS(.v17)],
  products: [
    .library(name: "GitKit", targets: ["GitKit"]),
    .library(name: "GitHubKit", targets: ["GitHubKit"]),
    .library(name: "GitHubUI", targets: ["GitHubUI"]),
    .library(name: "GitEngine", targets: ["GitEngine"]),
  ],
  dependencies: [v57("Component")],
  targets: [
    .target(name: "GitKit", swiftSettings: [.enableUpcomingFeature("ApproachableConcurrency")], ),
    .target(name: "GitHubKit", swiftSettings: [.enableUpcomingFeature("ApproachableConcurrency")], ),
    // The GitHub sign-in sheet (device flow) and its pieces, in ComponentKit: Git and Markdown show it.
    .target(
      name: "GitHubUI", dependencies: ["GitHubKit", .product(name: "ComponentKit", package: "Component")],
      swiftSettings: [
        .defaultIsolation(MainActor.self), .enableUpcomingFeature("ApproachableConcurrency"),
        .enableUpcomingFeature("MemberImportVisibility"),
      ]),
    // Git in Swift for repositories on iPhone and iPad, which have no git binary.
    .target(
      name: "GitEngine", dependencies: ["GitKit"],
      swiftSettings: [.enableUpcomingFeature("ApproachableConcurrency")], linkerSettings: [.linkedLibrary("z")]),
    .testTarget(
      name: "GitKitTests", dependencies: ["GitKit"],
      swiftSettings: [.enableUpcomingFeature("ApproachableConcurrency")], ),
    .testTarget(
      name: "GitHubKitTests", dependencies: ["GitHubKit"],
      swiftSettings: [.enableUpcomingFeature("ApproachableConcurrency")], ),
    .testTarget(
      name: "GitEngineTests", dependencies: ["GitEngine", "GitKit"],
      swiftSettings: [.enableUpcomingFeature("ApproachableConcurrency")], ),
  ])

#if os(Windows) || os(Linux)
// Off Apple platforms CryptoKit and os are v57/SwiftUI's stand-ins, and the GitHub token is kept by VaultKit's
// keychain (the Windows Credential Manager).
package.dependencies += [v57("SwiftUI"), v57("Vault")]
for target in package.targets {
  switch target.name {
  case "GitHubKit":
    target.dependencies += [
      .product(name: "CryptoKit", package: "SwiftUI"), .product(name: "VaultKit", package: "Vault"),
    ]
  case "GitHubUI":
    target.dependencies += [
      .product(name: "SwiftUI", package: "SwiftUI"), .product(name: "SwiftUIPortability", package: "SwiftUI"),
    ]
  case "GitEngine":
    target.dependencies += [.product(name: "CryptoKit", package: "SwiftUI")]
  case "GitKit":
    target.dependencies += [
      .product(name: "os", package: "SwiftUI"), .product(name: "SwiftUIPortability", package: "SwiftUI"),
    ]
  default: break
  }
}
#if os(Linux)
// zlib under Apple's module name for GitEngine (`apt install zlib1g-dev`).
package.targets.append(.systemLibrary(name: "zlib", path: "Sources/zlib", providers: [.apt(["zlib1g-dev"])]))
for target in package.targets where target.name == "GitEngine" {
  target.dependencies.append("zlib")
}
// RepositoryWatcher runs on inotify (SwiftUIPortability's DirectoryWatcher), which GitKit already depends on.
#endif
#endif
