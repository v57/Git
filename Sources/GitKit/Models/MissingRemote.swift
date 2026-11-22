import Foundation

/// A remote whose server answered that it has no such repository: one never created there (a repository whose
/// `origin` was set before the repository on GitHub was made), or one the login can't see. Its server let the login in,
/// so neither the key nor the token is the problem.
public struct MissingRemote: Sendable, Hashable, Codable {
  /// The remote's name, `origin`.
  public var name: String
  /// The address it fetches from, as it was when the server said so. A remote given another address since isn't
  /// missing any more (`RepositorySession` drops it on refresh).
  public var url: String

  public init(name: String, url: String) {
    self.name = name
    self.url = url
  }

  /// The repository on a host that names repositories `owner/name` (GitHub, GitLab, …): nil for a folder or a path
  /// the address doesn't split that way.
  public var hosted: HostedRepository? { HostedRepository(url: url) }

  /// The GitHub repository it names, which Publish on GitHub can create.
  public var gitHub: HostedRepository? { hosted.flatMap { $0.host == "github.com" ? $0 : nil } }

  /// Whether a server's or git's words say the repository isn't there, rather than that the login was refused:
  /// `ERROR: Repository not found.` (GitHub over SSH), `remote: Repository not found.` and git's
  /// `fatal: repository '…' not found` (over HTTPS), the in-app engine's `has no repository at`, GitLab's
  /// `The project you were looking for could not be found`.
  public static func says(_ message: String) -> Bool {
    let text = message.lowercased()
    if text.contains("repository not found") || text.contains("has no repository at")
      || text.contains("the project you were looking for could not be found")
    {
      return true
    }
    // fatal: repository 'https://github.com/owner/name.git/' not found
    guard let start = text.range(of: "repository '") else { return false }
    return text[start.upperBound...].range(of: "' not found") != nil
  }
}

/// `host/owner/name` out of a remote's address: `https://github.com/owner/name.git`, `git@github.com:owner/name.git` or
/// `ssh://git@github.com/owner/name`.
public struct HostedRepository: Sendable, Hashable {
  public var host: String
  public var owner: String
  public var name: String

  public init?(url: String) {
    let https = HTTPSRemote(remote: "", sshURL: url)?.url ?? url
    guard let components = URLComponents(string: https), let scheme = components.scheme?.lowercased(),
      scheme == "https" || scheme == "http", let host = components.host?.lowercased(), !host.isEmpty
    else { return nil }
    let parts = components.path.split(separator: "/").map(String.init)
    guard parts.count == 2 else { return nil }
    var name = parts[1]
    if name.lowercased().hasSuffix(".git") { name.removeLast(4) }
    guard !parts[0].isEmpty, !name.isEmpty else { return nil }
    self.host = host
    owner = parts[0]
    self.name = name
  }

  /// `github.com/owner/name`.
  public var displayName: String { "\(host)/\(owner)/\(name)" }
}
