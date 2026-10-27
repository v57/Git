import Foundation
import GitKit

extension LocalRepository {
  /// Local branches, then remote-tracking branches, each sorted by name, with upstreams, divergence from the
  /// upstream and from HEAD, and each tip's date and subject.
  @concurrent public func branches() async throws -> [Branch] {
    let context = try context()
    let head = try context.head()
    let headCommit = try context.headCommit()
    var branches: [Branch] = []
    let local = context.refs.list("refs/heads/")
    let remote = context.refs.list("refs/remotes/").filter { !context.refs.isSymbolic($0.name) }
    for (ref, id) in local + remote {
      let isRemote = ref.hasPrefix("refs/remotes/")
      let name = shortName(ref)
      let tip = try? context.objects.commit(id)
      var branch = Branch(
        refName: ref, name: name, isRemote: isRemote, isCurrent: head.branchRef == ref, sha: id.hex,
        date: tip?.committer.date, subject: tip?.subject ?? "")
      if !isRemote, let upstream = context.upstream(of: name) {
        branch.upstream = upstream.remote == "." ? shortName(upstream.mergeRef) : upstream.shortName
        if let tracking = context.refs.resolve(upstream.trackingRef) {
          let divergence = try RevWalk.divergence(context.objects, id, tracking)
          branch.ahead = divergence.ahead
          branch.behind = divergence.behind
        } else {
          branch.isUpstreamGone = true
        }
      }
      if let headCommit {
        let divergence = try RevWalk.divergence(context.objects, id, headCommit)
        branch.aheadOfHead = divergence.ahead
        branch.behindHead = divergence.behind
      }
      branches.append(branch)
    }
    return branches
  }

  /// Creates `name` at HEAD and switches to it when `checkout` is set. Before the first commit only switching works:
  /// the unborn branch is renamed.
  @concurrent public func createBranch(_ name: String, checkout: Bool = true) async throws {
    let context = try context()
    guard BranchName.isValid(name) else { throw GitEngineError.refused("“\(name)” isn't a valid branch name.") }
    let ref = "refs/heads/\(name)"
    guard context.refs.resolve(ref) == nil else {
      throw GitEngineError.refused("A branch named \(name) already exists.")
    }
    let from = try context.head()
    guard let commit = try context.headCommit() else {
      guard checkout else { throw GitEngineError.refused("Make a commit before creating another branch.") }
      try context.refs.setSymbolic("HEAD", to: ref)
      return
    }
    try context.refs.update(ref, to: commit, expected: .zero, message: "branch: Created from HEAD")
    if checkout {
      let fromName = from.branchName ?? commit.hex
      try context.refs.setSymbolic("HEAD", to: ref, message: "checkout: moving from \(fromName) to \(name)")
    }
  }

  /// Checks out a local branch, or for a remote branch a local one of the same name (created to track it when
  /// missing). Refuses when local changes to files that differ between the branches would be lost.
  @concurrent public func switchTo(_ branch: Branch) async throws {
    let context = try context()
    var localName = branch.name
    if branch.isRemote {
      localName = branch.localName
      let localRef = "refs/heads/\(localName)"
      if context.refs.resolve(localRef) == nil {
        guard let remote = branch.remoteName, let tip = context.refs.resolve(branch.refName) else {
          throw GitEngineError.notFound("\(branch.name) no longer exists.")
        }
        // Check the switch is possible before creating anything.
        var index = try context.readIndex()
        let checkout = Checkout(context: context)
        let current = try context.headCommit()
        let plan = try checkout.plan(
          from: current.map { try context.objects.commit($0).tree }, to: context.objects.commit(tip).tree, index: index)
        try context.refs.update(localRef, to: tip, expected: .zero, message: "branch: Created from \(branch.name)")
        let merge = context.fetchRefspecs(remote).lazy.compactMap { $0.reverseMap(branch.refName) }.first
        try context.updateConfig { config in
          try config.set("branch.\(localName).remote", remote)
          try config.set("branch.\(localName).merge", merge ?? localRef)
        }
        try checkout.apply(plan, to: &index)
        try context.writeIndex(index)
        let fromName = try context.head().branchName ?? current?.hex ?? "HEAD"
        try context.refs.setSymbolic(
          "HEAD", to: localRef, message: "checkout: moving from \(fromName) to \(localName)")
        return
      }
    }
    try checkout(context, branch: localName)
  }

  /// Switches HEAD to the local branch `name`, updating the working tree and index.
  func checkout(_ context: GitContext, branch name: String) throws {
    let ref = "refs/heads/\(name)"
    guard let target = context.refs.resolve(ref) else { throw GitEngineError.notFound("There's no branch \(name).") }
    let head = try context.head()
    if head.branchRef == ref { return }
    let current = try context.headCommit()
    var index = try context.readIndex()
    try Checkout(context: context).move(
      from: current.map { try context.objects.commit($0).tree }, to: context.objects.commit(target).tree,
      index: &index)
    try context.writeIndex(index)
    let fromName = head.branchName ?? current?.hex ?? "HEAD"
    try context.refs.setSymbolic("HEAD", to: ref, message: "checkout: moving from \(fromName) to \(name)")
  }
}
