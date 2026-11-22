import Foundation
import GitKit

/// What both apps say when a fetch, pull or push failed because the remote's server has no such repository: a GitHub
/// `origin` set before the repository was made there. Not the key, not the sign-in: the repository is missing.
public enum MissingRemoteNotice {
  /// The sidebar's and the header's word for it: "not on GitHub yet", or "not found on gitlab.com".
  public static func status(_ missing: MissingRemote) -> String {
    if missing.gitHub != nil { return String(localized: "not on GitHub yet") }
    let host = missing.hosted?.host ?? missing.url
    return String(localized: "not found on \(host)")
  }

  /// The notice: what's missing, and, for GitHub, what Publish on GitHub does (`branch` is what it pushes).
  public static func message(_ missing: MissingRemote, branch: String?, canPublish: Bool) -> String {
    let branch = branch ?? String(localized: "the current branch")
    guard let repository = missing.gitHub else {
      let place = missing.hosted?.displayName ?? missing.url
      return String(localized: """
        \(missing.name) points to \(place), which isn’t there: it was never created, or this login can’t see it. \
        Nothing was changed. Create it there, then try again.
        """)
    }
    var lines = [
      String(localized: """
        \(missing.name) points to \(repository.displayName), which GitHub doesn’t have: it was never created there, \
        or your GitHub account can’t see it. Nothing was changed.
        """)
    ]
    if canPublish {
      lines.append(String(localized: "Publish on GitHub creates it there, private unless you choose otherwise, and pushes \(branch) to it."))
    }
    return lines.joined(separator: "\n\n")
  }
}
