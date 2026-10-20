import ComponentKit
import SwiftUI
import VaultKit

/// The project's folders on the user's other devices that one of their Hubs reaches (the Vault app keeps those
/// devices as hosts via Hub): an SSH command for a terminal in the folder there.
struct OtherPlacesMenu: View {
  let root: URL

  var body: some View {
    let vault = Vault.shared
    let places = vault.project(atPath: root.path).map { vault.otherPlaces(of: $0) }?.filter { $0.sshCommand != nil } ?? []
    if !places.isEmpty {
      KitSubmenu("On Other Devices", systemImage: "point.3.connected.trianglepath.dotted") {
        ForEach(places) { place in
          Button("Copy SSH Command for \(place.deviceName)") { KitPasteboard.copy(place.sshCommand ?? "") }
            .help(place.path)
        }
      }
    }
  }
}
