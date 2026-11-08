import ComponentKit
import SwiftUI
import VaultKit

/// Settings' SSH Key card: the key this device signs in to SSH remotes with, to add to GitHub or any other server. It
/// shows what the vault published for the device, so opening Settings never makes a key.
public struct DeviceSSHKeyCard: View {
  @State private var vault = Vault.shared

  public init() {}

  private var key: VaultDeviceKey? { vault.deviceKeys.first { $0.id == vault.deviceID } }

  public var body: some View {
    if let key {
      FormCard(
        "SSH Key",
        footer: "SSH remotes sign in with this device’s key, which never leaves its Secure Enclave. Add it to your account on the server once."
      ) {
        GroupRow {
          VStack(alignment: .leading, spacing: 2) {
            Text(key.deviceName).fontWeight(.medium)
            if let fingerprint = key.fingerprint {
              Text(fingerprint)
                .kitFont(.callout)
                .foregroundStyle(.kitSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
            }
          }
        } trailing: {
          HStack(spacing: 8) {
            KitCopyButton(value: key.publicKey)
            if let url = URL(string: "https://github.com/settings/ssh/new") {
              Link("Add on GitHub", destination: url)
                .buttonStyle(.kit)
            }
          }
          .fixedSize()  // the fingerprint truncates first, never the button ("Add on Git…" on an iPhone)
        }
      }
    }
  }
}

/// Settings' sidebar: Copy Public Key, this device's SSH key (`ssh-…` line) for a server's or GitHub's key list, from
/// any pane. Nothing shows until the vault has published the device's key.
public struct DeviceKeyCopyButton: View {
  @State private var vault = Vault.shared

  public init() {}

  public var body: some View {
    if let key = vault.deviceKeys.first(where: { $0.id == vault.deviceID }) {
      KitCopyButton("Copy Public Key", systemImage: "key", value: key.publicKey)
        .buttonStyle(.kit)
        .help("Copies this device’s SSH key, to add to GitHub or a server")
    }
  }
}
