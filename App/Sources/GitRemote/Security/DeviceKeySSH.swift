#if canImport(GitEngine)
import Foundation
import GitEngine
import SSHKit
import VaultKit
import VaultUI

/// How GitEngine reaches SSH remotes: it speaks git, and this logs in with the key the vault keeps for this device.
/// GitHub, GitLab and Bitbucket are known ahead of time (`SSHKnownHosts`). About any other host it hasn't met the user is
/// asked, before this device's key signs anything, and a yes is remembered in the vault. A changed key is refused, as
/// for the user's other SSH hosts; `~/.ssh` plays no part.
enum DeviceKeySSH {
  static func install() {
    GitSSH.setConnector { address, command in
      let login: SSHServer
      do {
        login = try await MainActor.run { try server(for: address) }
      } catch {
        throw GitEngineError(.authentication, "This device has no SSH key to sign in with: \(error.localizedDescription)")
      }
      do {
        let connection = try await SSHConnection.connect(server: login)
        return Channel(connection: connection, channel: connection.open(command))
      } catch SSHTunnelError.authenticationFailed {
        throw GitEngineError(
          .authentication,
          "\(address.host) didn’t accept this device’s SSH key. Copy it from Settings ▸ Security and add it to your account there.")
      } catch let error as SSHTunnelError {
        throw GitEngineError(.network, error.localizedDescription)
      }
    }
  }

  /// `git` is the login repository hosts expect when the address names none.
  private static func server(for address: GitSSHAddress) throws -> SSHServer {
    let personal = Vault.shared.personalVault
    let port = address.port ?? 22
    let known = try? personal.store?.knownFingerprint(host: address.host, port: port)
    let trusted = vaultFingerprints(at: address.host, port: port)
    return SSHServer(
      host: address.host, port: port, user: address.user ?? "git", key: try key(),
      trust: .known(
        known,
        otherwise: .ask { key in
          if trusted.contains(key.fingerprint) { return true }
          return await VaultHostKeyRequest.shared.approve(
            key.fingerprint, keyType: key.type, host: key.host, port: key.port, in: personal)
        }))
  }

  /// The keys the vault already trusts for its hosts at this address (G-010): a Mac that published itself as
  /// "Studio.local", or a host whose other addresses include it. Its pin belongs to that host's route, so it doesn't
  /// pin the bare address; a key that matches it goes on without asking, and any other key is asked about as before.
  private static func vaultFingerprints(at address: String, port: Int) -> Set<String> {
    let address = address.lowercased()
    var fingerprints = Set<String>()
    let personal = Vault.shared.personalVault
    for vault in personal === Vault.shared ? [personal] : [Vault.shared, personal] {
      for host in vault.hosts where host.port == port {
        guard vault.addresses(of: host).contains(where: { $0.lowercased() == address }) else { continue }
        for fingerprint in [vault.knownHost(for: host)?.fingerprint, host.hub?.hostKeyFingerprint] {
          if let fingerprint, !fingerprint.isEmpty { fingerprints.insert(fingerprint) }
        }
      }
    }
    return fingerprints
  }

  private static func key() throws -> SSHKey {
    #if DEBUG
      // The simulator has no Secure Enclave key.
      if let path = ProcessInfo.processInfo.environment["GIT_DEBUG_SSH_KEY"] {
        return try SSHKey(importing: String(contentsOfFile: path, encoding: .utf8))
      }
    #endif
    return try RemoteRepositories.deviceKey()
  }

  /// A git service on its own connection, which ends with it.
  private nonisolated struct Channel: GitSSHChannel {
    let connection: SSHConnection
    let channel: SSHConnection.Channel

    func read() async throws -> Data? { try await channel.read() }
    func write(_ data: Data) { channel.write(data) }
    func finishWriting() { channel.finishWriting() }

    func finished() async throws -> (errorOutput: String, status: Int32?) {
      let output = try await channel.finished()
      return (String(decoding: output.stderr, as: UTF8.self), output.status)
    }

    func close() {
      channel.close()
      connection.close()
    }
  }
}
#endif
