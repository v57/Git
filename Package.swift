// swift-tools-version: 6.4

import PackageDescription

let package = Package(
  name: "Git", platforms: [.macOS(.v14), .iOS(.v17)],
  products: [
    .library(name: "GitKit", targets: ["GitKit"]),
    .library(name: "GitHubKit", targets: ["GitHubKit"]),
    .library(name: "GitEngine", targets: ["GitEngine"]),
  ],
  targets: [
    .target(name: "GitKit", swiftSettings: [.enableUpcomingFeature("ApproachableConcurrency")], ),
    .target(name: "GitHubKit", swiftSettings: [.enableUpcomingFeature("ApproachableConcurrency")], ),
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
  case "GitEngine":
    target.dependencies += [.product(name: "CryptoKit", package: "SwiftUI")]
  case "GitKit":
    target.dependencies += [
      .product(name: "os", package: "SwiftUI"), .product(name: "SwiftUIPortability", package: "SwiftUI"),
    ]
  default: break
  }
}
#if os(Windows)
// The app: a DLL the SwiftUI WinUI host loads (SwiftUI's Windows/scripts/build-app.ps1 -PackagePath <this package>
// -Product GitWinUI), built from the Xcode project's sources with its settings.
package.dependencies += [v57("Component"), v57("UpdateKit"), v57("Code"), v57("Dev")]
package.targets.append(
  .target(
    name: "GitApp",
    dependencies: [
      "GitKit", "GitHubKit", .product(name: "SwiftUI", package: "SwiftUI"), .product(name: "SwiftData", package: "SwiftUI"),
      .product(name: "SQLite3", package: "SwiftUI"), .product(name: "ComponentKit", package: "Component"),
      .product(name: "UpdateKit", package: "UpdateKit"), .product(name: "VaultKit", package: "Vault"),
      .product(name: "CodeHighlighting", package: "Code"), .product(name: "DevScreenshots", package: "Dev"),
    ],
    path: "Git", exclude: ["Assets.xcassets", "Git.entitlements"],
    swiftSettings: [
      .swiftLanguageMode(.v5), .defaultIsolation(MainActor.self), .enableUpcomingFeature("ApproachableConcurrency"),
      // On Apple platforms `import Foundation` brings Combine (ObservableObject, @Published), URLSession and the
      // file APIs SwiftUIPortability adds along: every file gets them here too.
      .unsafeFlags(
        ["Combine", "FoundationNetworking", "SwiftUIPortability"].flatMap { ["-Xfrontend", "-import-module", "-Xfrontend", $0] }),
    ]))
package.products.append(.library(name: "GitWinUI", type: .dynamic, targets: ["GitApp"]))
#endif
#endif
