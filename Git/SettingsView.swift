import ComponentKit
import GitHubKit
import GitKit
import SwiftUI

enum SettingsKeys {
  static let gitPath = "GitExecutablePath"
}

struct SettingsView: View {
  @AppStorage("SettingsPane") private var pane = "General"

  var body: some View {
    KitSettings(selection: $pane) {
      SettingsPane("General", systemImage: "gearshape") { GeneralSettingsView() }
      SettingsPane("GitHub", systemImage: "cloud", hue: .indigo) { GitHubSettingsView() }
    }
    .frame(width: 680, height: 460)
  }
}

private struct GeneralSettingsView: View {
  @AppStorage(SettingsKeys.gitPath) private var gitPath = ""
  @State private var resolved: String?
  @State private var version: String?

  var body: some View {
    FormCard(
      "Git",
      footer: "Leave empty to use Homebrew git, then /usr/bin/git (which needs the Command Line Tools). "
        + "Pushing uses your SSH agent, Keychain and git credential helpers, or your GitHub "
        + "account for github.com while you're signed in."
    ) {
      FormRow(
        "git executable", help: "Automatic when empty", systemImage: "terminal", hue: .gray,
        field: TextField("Automatic", text: $gitPath))
      if let resolved {
        FormRow("Using", help: [resolved, version].compactMap { $0 }.joined(separator: " · "), systemImage: "checkmark", hue: .green)
      } else {
        FormRow("Using", systemImage: "xmark", error: "git not found")
      }
    }
    .task(id: gitPath) {
      GitExecutable.customPath = gitPath
      resolved = GitExecutable.current?.path
      version = await GitExecutable.version()
    }
  }
}
