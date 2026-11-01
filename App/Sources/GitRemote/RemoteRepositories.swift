import CryptoKit
import Foundation
import GitKit
import SSHKit
import VaultKit

/// A machine a repository is on, and how to sign in to it: one of the vault's hosts (a device on the user's Hub, or
/// any SSH host saved in the Vault app) and the repository's folder there.
public struct RemoteTarget: Hashable, Sendable, Identifiable, Codable {
  /// The vault host's id.
  public var id: String
  public var name: String
  public var host: String
  public var port: Int
  public var user: String
  /// The OpenSSH host key line the device signed (a Hub device), pinned for the login.
  public var hostKey: String?
  /// The repository's folder there; `~/…` is the login's home folder.
  public var directory: String
  /// "via Hub" or "SSH": shown after the name.
  public var detail: String

  public init(
    id: String, name: String, host: String, port: Int, user: String, hostKey: String? = nil, directory: String,
    detail: String
  ) {
    self.id = id
    self.name = name
    self.host = host
    self.port = port
    self.user = user
    self.hostKey = hostKey
    self.directory = directory
    self.detail = detail
  }
}

/// A repository on another machine: one of the vault's projects that has a folder on a device of the user's Hub, or
/// a folder on one of the vault's SSH hosts added here. Git runs there over SSH (`SSHGitTransport`), so everything
/// the Mac app does works on it.
public struct RemoteRepository: Identifiable, Hashable, Sendable {
  public var id: String
  public var name: String
  public var icon: Data?
  public var targets: [RemoteTarget]

  public init(id: String, name: String, icon: Data? = nil, targets: [RemoteTarget]) {
    self.id = id
    self.name = name
    self.icon = icon
    self.targets = targets
  }

  /// The devices it is on, as Code lists its projects.
  public var places: String { targets.map(\.name).joined(separator: ", ") }
}

/// A folder on a vault host, added in this app ("Add Repository on a Mac"), kept in its defaults.
public struct SavedRemote: Codable, Hashable, Identifiable, Sendable {
  public var hostID: String
  public var path: String

  public init(hostID: String, path: String) {
    self.hostID = hostID
    self.path = path
  }

  public var id: String { hostID + ":" + path }
  public var name: String { (path as NSString).lastPathComponent }
}

/// The repositories on the user's other devices and how Git signs in to them, for both apps: the iPhone and iPad app
/// lists them beside its own, the Mac app under its repositories (On Your Devices).
@MainActor public enum RemoteRepositories {
  private static let savedKey = "remoteRepositories"

  /// The vault's projects on devices reachable through the user's Hubs (not the ones with a folder on this device,
  /// which git here opens), then the folders added here, by name.
  public static func all(vault: Vault = .shared) -> [RemoteRepository] {
    let here = vault.deviceID
    var repositories = vault.projects.compactMap { project -> RemoteRepository? in
      guard project.paths[here] == nil else { return nil }
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
      repositories += DebugRemotes.repositories
    #endif
    return repositories.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
  }

  /// The devices on the user's Hubs that have the project, at their Hub Network address, in its folder there.
  public static func targets(for project: VaultProject, vault: Vault) -> [RemoteTarget] {
    vault.otherPlaces(of: project).compactMap { place in
      guard let host = place.host else { return nil }
      var target = target(host, directory: place.path)
      target.name = place.deviceName
      return target
    }
  }

  public static func target(_ host: VaultHost, directory: String) -> RemoteTarget {
    RemoteTarget(
      id: host.id, name: host.displayName, host: host.hostname, port: host.port, user: host.user,
      hostKey: host.hub?.hostKey, directory: directory, detail: host.isViaHub ? "via Hub" : "SSH")
  }

  // MARK: Added here

  public static var saved: [SavedRemote] {
    get {
      guard let data = UserDefaults.standard.data(forKey: savedKey) else { return [] }
      return (try? JSONDecoder().decode([SavedRemote].self, from: data)) ?? []
    }
    set { UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: savedKey) }
  }

  public static func add(_ remote: SavedRemote) {
    guard !saved.contains(remote) else { return }
    saved.append(remote)
  }

  public static func remove(id: RemoteRepository.ID) {
    saved.removeAll { "saved:" + $0.id == id }
  }

  /// The hosts a folder can be added on: every SSH host in the vault that this device can sign in to.
  public static func hosts(vault: Vault = .shared) -> [VaultHost] {
    vault.hosts.filter { $0.auth != .importedKey && !$0.user.isEmpty }
      .sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
  }

  // MARK: Opening

  /// Signs in to `target` and finds the repository's working tree there (its top folder, with a `~/…` folder
  /// resolved): GitKit's repository running that machine's git through one SSH connection, and the connection.
  public static func open(
    _ target: RemoteTarget, vault: Vault = .shared
  ) async throws -> (repository: Repository, transport: SSHGitTransport) {
    let transport = SSHGitTransport(
      target: target, login: { try await MainActor.run { try RemoteRepositories.login(for: target, vault: vault) } },
      onNewHostKey: { fingerprint in Task { @MainActor in RemoteRepositories.trust(fingerprint, for: target, vault: vault) } }
    )
    let output = try await transport.shell(
      "cd \(SSHGitTransport.path(target.directory)) && exec git rev-parse --show-toplevel")
    guard output.status == 0 else {
      transport.close()
      let message = String(decoding: output.stderr, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
      throw SSHGitTransport.RemoteError.failed(
        message.contains("not a git repository") ? "\(target.directory) isn’t a Git repository." : message)
    }
    let top = String(decoding: output.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    let repository = Repository(url: URL(fileURLWithPath: top, isDirectory: true), runner: GitRunner(transport: transport))
    return (repository, transport)
  }

  /// The first of the repository's devices that answers, else every device's failure, one a line.
  public static func open(
    _ repository: RemoteRepository, vault: Vault = .shared, trying: (RemoteTarget) -> Void = { _ in }
  ) async throws -> (repository: Repository, transport: SSHGitTransport, target: RemoteTarget) {
    var failures: [String] = []
    for target in repository.targets {
      trying(target)
      do {
        let opened = try await open(target, vault: vault)
        return (opened.repository, opened.transport, target)
      } catch {
        failures.append("\(target.name): \(describe(error))")
      }
    }
    throw SSHGitTransport.RemoteError.failed(
      failures.isEmpty ? "\(repository.name) isn’t on a device Git can reach." : failures.joined(separator: "\n"))
  }

  /// An error's message for the screen.
  public static func describe(_ error: Error) -> String {
    if let error = error as? GitError { return error.message }
    return (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
  }

  // MARK: Signing in

  /// How Git signs in to a target: its host's user, this device's key (the Secure Enclave key every v57 app shares)
  /// or the host's saved password, and the host key: the one the device signed when it's on a Hub, else the one the
  /// vault trusts for the address (trusted on first use, as Shell and Code do).
  public static func login(for target: RemoteTarget, vault: Vault = .shared) throws -> SSHServer {
    #if DEBUG
      if let login = DebugRemotes.login(for: target) { return login }
    #endif
    // The ways to the user's devices are Personal's, whichever account's window asks.
    guard let host = vault.host(id: target.id) ?? vault.personalVault.host(id: target.id) else {
      throw LoginError.unknownHost
    }
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
  public static func trust(_ fingerprint: String, for target: RemoteTarget, vault: Vault = .shared) {
    guard target.hostKey == nil, vault.host(id: target.id) ?? vault.personalVault.host(id: target.id) != nil
    else { return }
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
  public static func fingerprint(ofHostKey line: String) -> String? {
    let fields = line.split(separator: " ")
    guard fields.count >= 2, let blob = Data(base64Encoded: String(fields[1])) else { return nil }
    let digest = Data(SHA256.hash(data: blob))
    return "SHA256:" + digest.base64EncodedString().replacingOccurrences(of: "=", with: "")
  }

  public enum LoginError: LocalizedError {
    case unknownHost
    case noUser(String)
    case importedKey(String)

    public var errorDescription: String? {
      switch self {
      case .unknownHost: "The device isn’t in the vault anymore."
      case .noUser(let name): "\(name) has no user name to sign in as. Set one in the Vault app."
      case .importedKey(let name): "\(name) signs in with a key another app imported. Use this device’s key instead."
      }
    }
  }
}
