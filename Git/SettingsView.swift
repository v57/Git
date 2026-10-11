import GitKit
import SwiftUI

enum SettingsKeys {
  static let gitPath = "GitExecutablePath"
}

struct SettingsView: View {
  @AppStorage(SettingsKeys.gitPath) private var gitPath = ""
  @State private var resolved: String?
  @State private var version: String?

  var body: some View {
    Form {
      Section {
        TextField("git executable", text: $gitPath, prompt: Text("Automatic"))
        LabeledContent("Using") {
          if let resolved {
            VStack(alignment: .trailing) {
              Text(resolved).textSelection(.enabled)
              if let version { Text(version).foregroundStyle(.secondary) }
            }
          } else {
            Text("git not found").foregroundStyle(.red)
          }
        }
      } footer: {
        Text(
          "Leave empty to use Homebrew git, then /usr/bin/git (which needs the Command Line Tools). "
            + "Pushing uses your SSH agent, Keychain and git credential helpers.")
      }
    }
    .formStyle(.grouped)
    .frame(width: 480)
    .task(id: gitPath) {
      GitExecutable.customPath = gitPath
      resolved = GitExecutable.current?.path
      version = await GitExecutable.version()
    }
  }
}
