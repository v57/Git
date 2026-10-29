import CryptoKit
import Foundation
import SSHKit
import VaultKit

/// A machine a repository is on, and how to sign in to it: one of the vault's hosts (a device on the user's Hub, or
/// any SSH host saved in the Vault app) and the repository's folder there.
struct RemoteTarget: Hashable, Sendable, Identifiable, Codable {
  /// The vault host's id.
  var id: String
  var name: String
  var host: String
  var port: Int
  var user: String
  /// The OpenSSH host key line the device signed (a Hub device), pinned for the login.
  var hostKey: String?
  /// The repository's folder there; `~/…` is the login's home folder.
  var directory: String
  /// "via Hub" or "SSH": shown after the name.
  var detail: String
}

/// A repository on another machine: one of the vault's projects that has a folder on a device of the user's Hub, or
/// a folder on one of the vault's SSH hosts added here. Git runs there over SSH (`SSHGitTransport`), so everything
/// the Mac app does works on it.
struct RemoteRepository: Identifiable, Hashable {
  var id: String
  var name: String
  var icon: Data?
  var targets: [RemoteTarget]
}

/// A folder on a vault host, added in this app ("Add Repository on a Mac"), kept in its defaults.
struct SavedRemote: Codable, Hashable, Identifiable {
  var hostID: String
  var path: String

  var id: String { hostID + ":" + path }
  var name: String { (path as NSString).lastPathComponent }
}

@MainActor enum RemoteRepositories {
  private static let savedKey = "remoteRepositories"

  /// The vault's projects on devices reachable through the user's Hubs, then the folders added here, by name.
  static func all(vault: Vault = .shared) -> [RemoteRepository] {
    var repositories = vault.projects.compactMap { project -> RemoteRepository? in
      let targets = targets(for: project, vault: vault)
      guard !targets.isEmpty else { return nil }
      return RemoteRepository(id: project.id, name: project.name, icon: project.icon, targets: targets)
    }
    for saved in saved {
      guard let host = vault.host(id: saved.hostID) else { continue }
      repositories.append(
        RemoteRepository(id: "saved:" + saved.id, name: saved.name, targets: [target(host, directory: saved.path)]))
    }
    #if DEBUG
      repositories += DebugLaunch.repositories
    #endif
    return repositories.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
  }

  /// The devices on the user's Hubs that have the project, at their Hub Network address, in its folder there.
  static func targets(for project: VaultProject, vault: Vault) -> [RemoteTarget] {
    vault.otherPlaces(of: project).compactMap { place in
      guard let host = place.host else { return nil }
      var target = target(host, directory: place.path)
      target.name = place.deviceName
      return target
    }
  }

  static func target(_ host: VaultHost, directory: String) -> RemoteTarget {
    RemoteTarget(
      id: host.id, name: host.displayName, host: host.hostname, port: host.port, user: host.user,
      hostKey: host.hub?.hostKey, directory: directory, detail: host.isViaHub ? "via Hub" : "SSH")
  }

  // MARK: Added here

  static var saved: [SavedRemote] {
    get {
      guard let data = UserDefaults.standard.data(forKey: savedKey) else { return [] }
      return (try? JSONDecoder().decode([SavedRemote].self, from: data)) ?? []
    }
    set { UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: savedKey) }
  }

  static func add(_ remote: SavedRemote) {
    guard !saved.contains(remote) else { return }
    saved.append(remote)
  }

  static func remove(id: RemoteRepository.ID) {
    saved.removeAll { "saved:" + $0.id == id }
  }

  /// The hosts a folder can be added on: every SSH host in the vault that this device can sign in to.
  static func hosts(vault: Vault = .shared) -> [VaultHost] {
    vault.hosts.filter { $0.auth != .importedKey && !$0.user.isEmpty }
      .sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
  }

  // MARK: Signing in

  /// How Git signs in to a target: its host's user, this device's key (the Secure Enclave key every v57 app shares)
  /// or the host's saved password, and the host key: the one the device signed when it's on a Hub, else the one the
  /// vault trusts for the address (trusted on first use, as Shell and Code do).
  static func login(for target: RemoteTarget, vault: Vault = .shared) throws -> SSHServer {
    #if DEBUG
      if let login = DebugLaunch.login(for: target) { return login }
    #endif
    guard let host = vault.host(id: target.id) else { throw LoginError.unknownHost }
    guard !host.user.isEmpty else { throw LoginError.noUser(host.displayName) }
    var server: SSHServer
    switch host.auth {
    case .password:
      server = SSHServer(
        host: target.host, port: target.port, user: host.user, password: VaultSecrets.password(for: host.id))
    case .deviceKey:
      server = SSHServer(host: target.host, port: target.port, user: host.user, key: try deviceKey())
    case .importedKey:
      throw LoginError.importedKey(host.displayName)
    }
    if let line = target.hostKey, let fingerprint = fingerprint(ofHostKey: line) {
      server.knownFingerprint = fingerprint
    } else {
      server.knownFingerprint = try? vault.store?.knownFingerprint(host: target.host, port: target.port)
    }
    return server
  }

  /// Remembers a host's key after the first login to it.
  static func trust(_ fingerprint: String, for target: RemoteTarget, vault: Vault = .shared) {
    guard target.hostKey == nil, vault.host(id: target.id) != nil else { return }
    try? vault.store?.trust(fingerprint: fingerprint, host: target.host, port: target.port)
  }

  /// This device's SSH key (Secure Enclave, shared by the v57 apps).
  private static func deviceKey() throws -> SSHKey {
    let key = try VaultIdentity.key()
    let blob = VaultIdentity.publicKeyBlob(key)
    return SSHKey(kind: .ecdsaP256, publicKeyBlob: Array(blob), comment: VaultDevice.name) { data in
      Array(try VaultIdentity.sshSignature(Data(data), key: key))
    }
  }

  /// `SHA256:…` for an OpenSSH host key line ("ecdsa-sha2-nistp256 AAAA… comment"), as libssh2 reports it.
  static func fingerprint(ofHostKey line: String) -> String? {
    let fields = line.split(separator: " ")
    guard fields.count >= 2, let blob = Data(base64Encoded: String(fields[1])) else { return nil }
    let digest = Data(SHA256.hash(data: blob))
    return "SHA256:" + digest.base64EncodedString().replacingOccurrences(of: "=", with: "")
  }

  enum LoginError: LocalizedError {
    case unknownHost
    case noUser(String)
    case importedKey(String)

    var errorDescription: String? {
      switch self {
      case .unknownHost: "The device isn’t in the vault anymore."
      case .noUser(let name): "\(name) has no user name to sign in as. Set one in the Vault app."
      case .importedKey(let name): "\(name) signs in with a key another app imported. Use this device’s key instead."
      }
    }
  }
}
