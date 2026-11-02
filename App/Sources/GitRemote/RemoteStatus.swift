import Foundation
import GitKit
import VaultKit

/// A repository's status as the vault keeps it for the user's other devices (`VaultProject.Status`): each Mac writes
/// its repositories' (`Vault.setStatus`), and the other devices show it before they reach the Mac, and when they can't.
extension VaultProject.Status {
  /// How a repository here is: `status`'s branch, counts and files (conflicts, then staged, then unstaged), and
  /// `activity`'s commit and push dates for other devices' orders. No line counts or dates of uncommitted changes: it
  /// changes only when the repository's state does.
  public init(_ status: WorkingTreeStatus, activity: RepositoryActivity? = nil) {
    let summary = RepositorySummary(status)
    let files = (status.conflicted + status.staged + status.unstaged).map { change in
      File(path: change.path, kind: change.kind.letter, area: change.area.rawValue)
    }
    self.init(
      branch: summary.branch, changeCount: summary.changeCount, ahead: summary.ahead, behind: summary.behind,
      hasUpstream: summary.hasUpstream, conflictCount: summary.conflictCount, operation: summary.operation?.rawValue,
      files: files, lastCommit: activity?.lastCommit, lastPush: activity?.lastPush)
  }

  /// The status as GitKit's, for the Changes list until the repository is read: the kept files (the first
  /// `fileLimit`), no commit (the device didn't keep one) and, with an upstream, `origin/<branch>` (its name wasn't
  /// kept either).
  public var workingTreeStatus: WorkingTreeStatus {
    var status = WorkingTreeStatus()
    status.branch = branch
    status.ahead = ahead
    status.behind = behind
    if hasUpstream, let branch { status.upstream = "origin/" + branch }
    status.operation = operation.flatMap(RepositoryOperation.init(rawValue:))
    for file in files {
      guard let kind = ChangeKind(letter: file.kind), let area = ChangeArea(rawValue: file.area) else { continue }
      let change = FileChange(path: file.path, kind: kind, area: area)
      switch area {
      case .staged: status.staged.append(change)
      case .unstaged: status.unstaged.append(change)
      case .conflicted: status.conflicted.append(change)
      }
    }
    return status
  }

  /// What a session shows until it reads the repository (`RepositorySession.restore`): the kept changes, with no line
  /// counts, branches or remotes.
  public var snapshot: RepositorySession.Snapshot { RepositorySession.Snapshot(status: workingTreeStatus) }

  /// The sidebar's marks: the device's counts, not the kept files'.
  public var summary: RepositorySummary {
    var summary = RepositorySummary(workingTreeStatus)
    summary.changeCount = changeCount
    summary.conflictCount = conflictCount
    summary.hasUpstream = hasUpstream
    return summary
  }
}

extension RemoteRepository {
  /// How the repository was when its device last looked, and which device: the first of its devices (in the order
  /// they're tried) that kept a status.
  public var lastSeen: (device: String, status: VaultProject.Status)? {
    for target in targets {
      if let device = target.device, let status = statuses[device] { return (target.name, status) }
    }
    return nil
  }
}
