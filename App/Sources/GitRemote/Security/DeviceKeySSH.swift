#if canImport(GitEngine)
import Foundation
import GitEngine
import SSHKit
import VaultKit

/// How GitEngine reaches SSH remotes: it speaks git, and this logs in with the key the vault keeps for this device. A
/// host it hasn't met is remembered in the vault on first use and a changed key is refused, as for the user's other
/// SSH hosts; `~/.ssh` plays no part.
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
        if login.knownFingerprint == nil {
          let fingerprint = connection.hostKeyFingerprint
          await MainActor.run {
            try? Vault.shared.personalVault.store?.trust(fingerprint: fingerprint, host: login.host, port: login.port)
          }
        }
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
    var server = SSHServer(
      host: address.host, port: address.port ?? 22, user: address.user ?? "git", key: try key())
    server.knownFingerprint = try? Vault.shared.personalVault.store?.knownFingerprint(
      host: server.host, port: server.port)
    return server
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
