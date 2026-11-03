import Foundation

/// A remote git reaches over SSH, and the same repository's address over HTTPS.
public struct HTTPSRemote: Sendable, Hashable {
  public var remote: String
  public var host: String
  public var url: String

  public init(remote: String, host: String, url: String) {
    self.remote = remote
    self.host = host
    self.url = url
  }

  /// `git@github.com:owner/repo.git` or `ssh://git@github.com:22/owner/repo.git` as
  /// `https://github.com/owner/repo.git`; nil for any other URL, and for a path from the login's home (`~/repo.git`).
  public init?(remote: String, sshURL: String) {
    var address: Substring
    var path: Substring
    if let scheme = sshURL.range(of: "://") {
      guard ["ssh", "git+ssh", "ssh+git"].contains(sshURL[..<scheme.lowerBound]) else { return nil }
      let rest = sshURL[scheme.upperBound...]
      guard let slash = rest.firstIndex(of: "/") else { return nil }
      address = rest[..<slash]
      path = rest[rest.index(after: slash)...]
    } else {
      guard let colon = sshURL.firstIndex(of: ":"), !sshURL[..<colon].contains("/") else { return nil }
      address = sshURL[..<colon]
      path = sshURL[sshURL.index(after: colon)...]
    }
    if let login = address.lastIndex(of: "@") { address = address[address.index(after: login)...] }
    if let port = address.firstIndex(of: ":") { address = address[..<port] }
    while path.hasPrefix("/") { path = path.dropFirst() }
    let url = "https://\(address)/\(path)"
    guard !address.isEmpty, !path.isEmpty, !path.hasPrefix("~"), URL(string: url)?.host != nil else { return nil }
    self.init(remote: remote, host: String(address).lowercased(), url: url)
  }
}

/// A remote reached over HTTPS, and the same repository's address over SSH: the reverse of `HTTPSRemote`.
public struct SSHRemote: Sendable, Hashable {
  public var host: String
  public var url: String

  /// `https://github.com/owner/repo.git` as `git@github.com:owner/repo.git`, the login repository hosts take. Nil for
  /// any other URL. A login or port in the address stays behind: they're HTTPS's.
  public init?(httpsURL: String) {
    guard let components = URLComponents(string: httpsURL), let scheme = components.scheme?.lowercased(),
      scheme == "https" || scheme == "http", let host = components.host, !host.isEmpty
    else { return nil }
    var path = Substring(components.path)
    while path.hasPrefix("/") { path = path.dropFirst() }
    while path.hasSuffix("/") { path = path.dropLast() }
    guard !path.isEmpty else { return nil }
    self.host = host.lowercased()
    url = "git@\(host):\(path)"
  }
}

extension GitError {
  /// Whether git's ssh got no further than the login: an unknown host key, which a session without a terminal can't
  /// accept, or no key the server takes. A network failure is not one: HTTPS wouldn't get through either.
  public var isSSHLoginFailure: Bool {
    message.contains("Host key verification failed") || message.contains("Permission denied (")
  }
}
