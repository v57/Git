import Foundation

/// Groups imported repositories by the folder that holds them, one level deep.
///
/// Repositories directly inside the same folder form a group named after that folder, with the
/// folder above it as a note: `~/Developer/Hub/Apps/a` and `…/Apps/b` make `Apps` (`Hub`). A
/// repository deeper down belongs only to its own folder's group, never to an ancestor's, and a
/// repository alone in its folder stays ungrouped.
public enum RepoGrouping {
  public struct Group: Equatable, Sendable {
    /// The folder the repositories are in.
    public var directory: URL
    public var name: String
    /// The name of the folder above `directory`.
    public var note: String
    public var repositories: [URL]
  }

  /// The groups (sorted by name) and the repositories left ungrouped (sorted by path).
  public static func groups(for repositories: [URL], minimumSize: Int = 2)
    -> (groups: [Group], ungrouped: [URL])
  {
    var byParent: [URL: [URL]] = [:]
    for repository in repositories {
      let repository = repository.standardizedFileURL
      byParent[repository.deletingLastPathComponent().standardizedFileURL, default: []]
        .append(repository)
    }
    var groups: [Group] = []
    var ungrouped: [URL] = []
    for (parent, members) in byParent {
      let members = members.sorted(by: pathOrder)
      if members.count >= minimumSize, parent.path != "/" {
        groups.append(
          Group(
            directory: parent, name: parent.lastPathComponent,
            note: parent.deletingLastPathComponent().lastPathComponent, repositories: members))
      } else {
        ungrouped += members
      }
    }
    groups.sort {
      let order = $0.name.localizedStandardCompare($1.name)
      return order == .orderedSame ? pathOrder($0.directory, $1.directory) : order == .orderedAscending
    }
    return (groups, ungrouped.sorted(by: pathOrder))
  }

  private static func pathOrder(_ lhs: URL, _ rhs: URL) -> Bool {
    lhs.path.localizedStandardCompare(rhs.path) == .orderedAscending
  }
}
