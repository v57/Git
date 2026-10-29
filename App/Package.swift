// swift-tools-version: 6.4

import PackageDescription

/// Another v57 repository: GitHub's main branch, or the checkout next to this repository with `V57_LOCAL=1` (in
/// Xcode, open Git-Local.xcworkspace instead).
func v57(_ name: String) -> Package.Dependency {
  Context.environment["V57_LOCAL"] == nil
    ? .package(url: "https://github.com/v57/\(name).git", branch: "main") : .package(path: "../../\(name)")
}

/// This repository's libraries, the package at "..": SwiftPM names a path dependency after its folder, which is Git in
/// the main checkout and the worktree's own name in a worktree.
let kits = String(Context.packageDirectory.split(whereSeparator: { $0 == "/" || $0 == "\\" }).dropLast().last ?? "Git")

/// The apps, a package of their own so the libraries (the package one folder up, which Markdown and Dev depend on)
/// carry none of the apps' dependencies:
///
/// - GitApp: the Mac app, all of it but its entry point (Sources/Git/GitMain.swift). Git.xcodeproj builds that file
///   into Git.app with Resources (the icon, assets and entitlements); on Linux and Windows the Git target below does.
/// - GitMobileApp: the iPhone and iPad app, all of it but its entry point (Sources/GitMobile/GitMobileMain.swift, the
///   Xcode project's Git iOS target).
/// - GitUI: what both apps show: the diff's hunk cards and highlighting, the change kind badge, the message sheet and
///   the GitHub sign-in and settings.
let appSettings: [SwiftSetting] = [
  .swiftLanguageMode(.v5), .defaultIsolation(MainActor.self), .enableUpcomingFeature("ApproachableConcurrency"),
  .enableUpcomingFeature("MemberImportVisibility"),
]

let package = Package(
  name: "GitApp", platforms: [.macOS(.v15), .iOS(.v17)],
  products: [
    .library(name: "GitApp", targets: ["GitApp"]),
    .library(name: "GitMobileApp", targets: ["GitMobileApp"]),
  ],
  dependencies: [
    // This repository's libraries.
    .package(path: ".."),
    // CodeHighlighting for the diffs; the shared design, the user's vault (repositories, devices, accounts), in-app
    // updates and SSH to the user's Macs.
    v57("Code"), v57("Component"), v57("Vault"), v57("UpdateKit"), v57("SSH"),
  ],
  targets: [
    .target(
      name: "GitUI",
      dependencies: [
        .product(name: "GitKit", package: kits), .product(name: "GitHubKit", package: kits),
        .product(name: "CodeHighlighting", package: "Code"), .product(name: "ComponentKit", package: "Component"),
        .product(name: "VaultKit", package: "Vault"),
      ],
      swiftSettings: appSettings),
    .target(
      name: "GitApp",
      dependencies: [
        "GitUI", .product(name: "GitKit", package: kits), .product(name: "GitHubKit", package: kits),
        .product(name: "CodeHighlighting", package: "Code"), .product(name: "UpdateKit", package: "UpdateKit"),
        .product(name: "VaultKit", package: "Vault"), .product(name: "VaultUI", package: "Vault"),
        .product(name: "ComponentKit", package: "Component"),
      ],
      swiftSettings: appSettings),
    .target(
      name: "GitMobileApp",
      dependencies: [
        "GitUI", .product(name: "GitKit", package: kits), .product(name: "GitEngine", package: kits),
        .product(name: "GitHubKit", package: kits), .product(name: "CodeHighlighting", package: "Code"),
        .product(name: "VaultKit", package: "Vault"), .product(name: "ComponentKit", package: "Component"),
        .product(name: "SSHKit", package: "SSH"),
      ],
      swiftSettings: appSettings),
  ])

// Dev's screenshot scenes (`.dev/screenshots.json`).
package.dependencies += [v57("Dev")]
for target in package.targets where target.name == "GitApp" {
  target.dependencies += [.product(name: "DevScreenshots", package: "Dev")]
}

#if os(Windows) || os(Linux)
// Off Apple platforms SwiftUI, SwiftData and SQLite3 are v57/SwiftUI's, and SwiftUIPortability adds the Foundation
// APIs swift-corelibs-foundation lacks. Only here: on Apple platforms the apps use Apple's frameworks, and
// v57/SwiftUI (with its swift-syntax) stays out of the package graph Xcode resolves.
package.dependencies += [v57("SwiftUI")]
// On Apple platforms `import Foundation` brings Combine (ObservableObject, @Published), URLSession and the file APIs
// SwiftUIPortability adds along: every file gets them here too.
let offAppleSettings =
  appSettings + [
    .unsafeFlags(
      ["Combine", "FoundationNetworking", "SwiftUIPortability"].flatMap {
        ["-Xfrontend", "-import-module", "-Xfrontend", $0]
      })
  ]
for target in package.targets where ["GitUI", "GitApp"].contains(target.name) {
  target.dependencies += [
    .product(name: "SwiftUI", package: "SwiftUI"), .product(name: "SwiftUIPortability", package: "SwiftUI"),
  ]
  if target.name == "GitApp" {
    target.dependencies += [
      .product(name: "SwiftData", package: "SwiftUI"), .product(name: "SQLite3", package: "SwiftUI"),
    ]
  }
  target.swiftSettings = offAppleSettings
}
// The entry point, Sources/Git/GitMain.swift, which the Xcode project builds on Apple platforms.
#if os(Windows)
// The app: a DLL the SwiftUI WinUI host loads (SwiftUI's Windows/scripts/build-app.ps1 -PackagePath <this folder>
// -Product GitWinUI).
package.targets.append(
  .target(
    name: "Git", dependencies: ["GitApp", .product(name: "SwiftUI", package: "SwiftUI")],
    swiftSettings: offAppleSettings))
package.products.append(.library(name: "GitWinUI", type: .dynamic, targets: ["Git"]))
#elseif os(Linux)
// The app on SwiftUI's GTK backend (in App/: V57_LOCAL=1 swift build --product Git; SwiftUI's Linux/scripts/build-app
// stages it).
package.targets.append(
  .executableTarget(
    name: "Git", dependencies: ["GitApp", .product(name: "SwiftUI", package: "SwiftUI")],
    swiftSettings: offAppleSettings))
package.products.append(.executable(name: "Git", targets: ["Git"]))
#endif
#endif
