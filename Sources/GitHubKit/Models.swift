import Foundation

/// The signed-in user, from `GET /user`.
public struct GitHubUser: Sendable, Hashable, Codable {
  public var login: String
  public var name: String?
  public var avatarURL: URL?
  public var htmlURL: URL?

  public init(login: String, name: String? = nil, avatarURL: URL? = nil, htmlURL: URL? = nil) {
    self.login = login
    self.name = name
    self.avatarURL = avatarURL
    self.htmlURL = htmlURL
  }

  enum CodingKeys: String, CodingKey {
    case login, name
    case avatarURL = "avatar_url"
    case htmlURL = "html_url"
  }
}

/// An organization the user belongs to, from `GET /user/orgs`.
public struct GitHubOrganization: Sendable, Hashable, Codable, Identifiable {
  public var login: String
  public var avatarURL: URL?

  public var id: String { login }

  public init(login: String, avatarURL: URL? = nil) {
    self.login = login
    self.avatarURL = avatarURL
  }

  enum CodingKeys: String, CodingKey {
    case login
    case avatarURL = "avatar_url"
  }
}

/// A repository on GitHub.
public struct GitHubRepository: Sendable, Hashable, Codable {
  public var name: String
  /// `owner/name`.
  public var fullName: String
  public var isPrivate: Bool
  public var htmlURL: URL
  /// The HTTPS URL git pushes to.
  public var cloneURL: URL
  public var sshURL: String?
  public var defaultBranch: String?

  enum CodingKeys: String, CodingKey {
    case name
    case fullName = "full_name"
    case isPrivate = "private"
    case htmlURL = "html_url"
    case cloneURL = "clone_url"
    case sshURL = "ssh_url"
    case defaultBranch = "default_branch"
  }
}

/// A repository to create. Nothing is pushed: the repository starts empty.
public struct NewRepository: Sendable, Hashable {
  public var name: String
  public var description: String
  public var isPrivate: Bool
  /// The organization that owns it, or `nil` for the signed-in user.
  public var organization: String?

  public init(name: String, description: String = "", isPrivate: Bool, organization: String? = nil) {
    self.name = name
    self.description = description
    self.isPrivate = isPrivate
    self.organization = organization
  }

  /// GitHub keeps letters, digits, `.`, `-` and `_` and turns every other run of characters into
  /// one `-`, as its New Repository page does.
  public static func normalizedName(_ name: String) -> String {
    var result = ""
    var pendingDash = false
    for scalar in name.trimmingCharacters(in: .whitespaces).unicodeScalars {
      let allowed =
        scalar.isASCII
        && (CharacterSet.alphanumerics.contains(scalar) || "._-".unicodeScalars.contains(scalar))
      if allowed {
        if pendingDash { result.append("-") }
        pendingDash = false
        result.unicodeScalars.append(scalar)
      } else {
        pendingDash = true
      }
    }
    if pendingDash { result.append("-") }
    return result
  }
}

/// A token, the login it belongs to and the scopes GitHub granted it.
public struct GitHubCredential: Sendable, Hashable {
  public var login: String
  public var token: String
  public var scopes: Set<String>

  public init(login: String, token: String, scopes: Set<String>) {
    self.login = login
    self.token = token
    self.scopes = scopes
  }

  public var permissions: GitHubPermissions { GitHubPermissions(scopes: scopes) }
}
