import Foundation
import GitKit

/// GitEngine as `Repository`'s network path, and what repositories on iPhone and iPad go through: everything a security
/// level decides about clone, fetch, pull and push.
///
/// Where the level lets `git` take over, it does for the causes that say the app's way can't work: the vault's key or
/// the token refused or missing, or a repository or setup the engine doesn't do. A real answer (a non-fast-forward, a
/// server refusing the update) and a network failure stay as they are: git would only meet them again.
public struct GitEngineNetwork: GitNetworkEngine {
  public init() {}

  /// Whether `error` says the engine's way can't work here, rather than what the server or network said.
  static func gitMightDoBetter(_ error: any Error) -> Bool {
    switch (error as? GitEngineError)?.kind {
    case .authentication, .notFound, .corrupt, .unsupported, .notARepository: true
    default: false
    }
  }

  public func restoreMovedRemotes(in worktree: URL) {
    guard let context = try? GitContext(worktree: worktree) else { return }
    RemoteMover(context: context).restore()
  }

  @concurrent public func perform(
    _ action: GitNetworkAction, in worktree: URL, request: GitNetworkRequest
  ) async throws -> GitNetworkOutcome {
    let route: Route
    do {
      route = Route(context: try GitContext(worktree: worktree, settings: request.settings), request: request)
    } catch where request.hasGit && request.level < .vaultKeyOnly && Self.gitMightDoBetter(error) {
      return .useGit(reason: "\(error)")
    }
    return try await route.run(action)
  }

  @concurrent public func clone(
    _ remote: String, to destination: URL, request: GitNetworkRequest
  ) async throws -> GitNetworkOutcome {
    try await CloneRoute(request: request).run(remote, to: destination)
  }
}

/// How a remote's address is reached.
enum RemoteAddress {
  case ssh(GitSSHAddress)
  case https(URL)
  /// Plain HTTP or git's own protocol: the network without encryption.
  case unencrypted
  /// A path on this machine, or a `file://` address.
  case local
  /// `helper::address`.
  case helper

  init(_ text: String) {
    if let address = GitSSHAddress(text) {
      self = .ssh(address)
    } else if let scheme = text.range(of: "://").map({ text[..<$0.lowerBound].lowercased() }) {
      switch scheme {
      case "https": self = URL(string: text).map(RemoteAddress.https) ?? .helper
      case "http", "git": self = .unencrypted
      case "file": self = .local
      default: self = .helper
      }
    } else {
      self = text.contains("::") ? .helper : .local
    }
  }
}

/// What the user's own SSH setup makes of an address, which only their `ssh` can follow. Shared by actions and clones.
enum SSHSetup {
  /// Why an address needs the user's `ssh`: their config sends it elsewhere. Nil when the app can log in to it itself.
  static func aliasReason(_ address: GitSSHAddress, _ request: GitNetworkRequest) async -> String? {
    guard let resolved = await request.sshClientAddress?(address.host) else { return nil }
    if resolved.hostname.lowercased() != address.host.lowercased() {
      return "\(address.host) is a name from your SSH config (~/.ssh/config), for \(resolved.hostname)."
    }
    if resolved.isProxied { return "Your SSH config (~/.ssh/config) reaches \(address.host) through a proxy." }
    if address.port == nil, let port = resolved.port, port != 22 {
      return "Your SSH config (~/.ssh/config) reaches \(address.host) on port \(port)."
    }
    return nil
  }

  /// Why an address has to go through the user's `git` and `ssh` when they're there.
  static func gitReason(_ url: String, settings: GitConfig, request: GitNetworkRequest) async -> String? {
    switch RemoteAddress(url) {
    case .ssh(let address):
      let environment = ProcessInfo.processInfo.environment
      if settings.value("core.sshCommand") != nil || environment["GIT_SSH_COMMAND"] != nil || environment["GIT_SSH"] != nil {
        return "You run ssh your own way (core.sshCommand)."
      }
      if address.user == nil { return "\(url) names no login, which your SSH setup decides." }
      return await aliasReason(address, request)
    case .https(let url):
      if url.user != nil { return "The address carries its own login." }
      return httpReason(settings)
    case .unencrypted: return nil
    case .local, .helper: return "The app doesn't reach \(url) itself."
    }
  }

  /// Settings that change how git talks HTTP, which URLSession doesn't read.
  private static func httpReason(_ settings: GitConfig) -> String? {
    let names = settings.names(in: "http")
    for key in ["proxy", "extraheader", "sslcert", "sslkey", "sslcainfo", "sslcapath", "sslverify", "cookiefile"]
    where names.contains(key) {
      return "Your git settings change how it talks HTTP (http.\(key))."
    }
    return settings.subsections(of: "http").isEmpty ? nil : "Your git settings change how it talks HTTP for some sites."
  }
}

/// One network action in one repository.
private struct Route {
  enum Direction { case fetch, push }

  let context: GitContext
  let request: GitNetworkRequest

  private var level: GitSecurityLevel { request.level }
  private var canUseGit: Bool { request.hasGit && level < .vaultKeyOnly }
  private var checks: RepositoryChecks { RepositoryChecks(context: context) }

  func run(_ action: GitNetworkAction) async throws -> GitNetworkOutcome {
    if level < .sshOnly { RemoteMover(context: context).restore() }
    switch action {
    case .fetch: return try await fetch()
    case .pull: return try await pull()
    case .push(let force): return try await push(force: force)
    case .deleteBranch(let name, let remote, let expected): return try await delete(name, on: remote, expected: expected)
    }
  }

  private func fetch() async throws -> GitNetworkOutcome {
    let names = context.remotes.filter { !context.settings.bool("remote.\($0).skipFetchAll", default: false) }
    return try await gate(names, .fetch, obstacle: checks.format ?? fetchObstacle(names)) { allowed in
      try await Fetcher(context: context).fetch(remotes: allowed, progress: request.progress)
      return .done
    }
  }

  private func pull() async throws -> GitNetworkOutcome {
    guard let branch = try context.head().branchName else {
      throw GitEngineError.refused("HEAD is detached. Switch to a branch before pulling.")
    }
    guard let upstream = context.upstream(of: branch) else {
      if canUseGit { return .useGit(reason: "\(branch) tracks nothing: git says what it wants.") }
      throw GitEngineError.refused("\(branch) doesn't track a remote branch. Push it first to set one.")
    }
    // git-lfs would download what the merge brings in over its own connection, with the user's credentials.
    if level == .vaultKeyOnly, request.hasGit, checks.usesLFS {
      throw GitEngineError.refused(
        "This repository uses Git LFS, whose files git-lfs downloads over its own connection. Vault key only can fetch it but not pull it.")
    }
    if upstream.remote == "." { return request.hasGit ? .fetched : try await pullHere() }
    return try await gate([upstream.remote], .fetch, obstacle: checks.format ?? fetchObstacle([upstream.remote])) { _ in
      guard request.hasGit else { return try await pullHere() }
      let refs = try await Fetcher(context: context).fetch(
        upstream.remote, prune: context.prunesOnPull(upstream.remote), progress: request.progress)
      guard refs.contains(where: { $0.name == upstream.mergeRef }) else {
        throw GitEngineError.refused("\(upstream.shortName) doesn't exist on the remote.")
      }
      return .fetched
    }
  }

  private func pullHere() async throws -> GitNetworkOutcome {
    try await LocalRepository(url: context.worktree).pull(progress: request.progress)
    return .done
  }

  private func push(force: Bool) async throws -> GitNetworkOutcome {
    guard let branch = try context.head().branchName else {
      throw GitEngineError.refused("HEAD is detached. Switch to a branch before pushing.")
    }
    let remote = try context.pushRemote(for: branch)
    if level == .vaultKeyOnly, checks.usesLFS {
      throw GitEngineError.refused(
        "This repository uses Git LFS. Vault key only can’t send its files, and pushing their pointers without them would damage the repository.")
    }
    return try await gate([remote], .push, obstacle: checks.format ?? pushObstacle(remote)) { _ in
      try await Pusher(context: context).push(force: force, progress: request.progress)
      return .done
    }
  }

  private func delete(_ name: String, on remote: String, expected: String) async throws -> GitNetworkOutcome {
    guard let expected = ObjectID(hex: expected) else { throw GitEngineError.refused("“\(expected)” isn't a commit.") }
    let hook = request.hasGit && level < .vaultKeyOnly && checks.hasHook("pre-push") ? "A pre-push hook is active." : nil
    return try await gate([remote], .push, obstacle: checks.format ?? hook) { _ in
      try await Pusher(context: context).delete(name, on: remote, expected: expected, progress: request.progress)
      return .done
    }
  }

  /// Why a fetch needs git (or, at `vaultKeyOnly`, is refused).
  private func fetchObstacle(_ remotes: [String]) -> String? {
    guard request.hasGit else { return nil }
    let settings = context.settings
    if checks.hasSubmodules, settings.value("fetch.recurseSubmodules")?.lowercased() != "false" {
      return "This repository has submodules, and Git in the app doesn't fetch those."
    }
    for key in ["fetch.fsckObjects", "transfer.fsckObjects", "fetch.pruneTags"] where settings.bool(key, default: false) {
      return "Git in the app doesn't do \(key)."
    }
    for remote in remotes {
      for key in ["uploadpack", "proxy", "vcs", "partialclonefilter", "promisor", "prunetags"]
      where settings.value("remote.\(remote).\(key)") != nil {
        return "Git in the app doesn't do remote.\(remote).\(key)."
      }
    }
    return nil
  }

  /// Why a push needs git (or, at `vaultKeyOnly`, is refused). The in-app path runs no `pre-push` hook and sends no
  /// LFS objects; `vaultKeyOnly` says so in Settings and handled LFS before this.
  private func pushObstacle(_ remote: String) -> String? {
    guard request.hasGit else { return nil }
    let settings = context.settings
    if level < .vaultKeyOnly {
      if checks.hasHook("pre-push") { return "A pre-push hook is active." }
      if checks.usesLFS { return "This repository uses Git LFS." }
    }
    if let mode = settings.value("push.default")?.lowercased(), mode == "matching" || mode == "nothing" {
      return "Git in the app doesn't do push.default \(mode)."
    }
    for key in ["push.followTags", "push.gpgSign"] where settings.value(key).map({ !["false", "no", "off", "0"].contains($0.lowercased()) }) == true {
      return "Git in the app doesn't do \(key)."
    }
    if settings.value("push.pushOption") != nil { return "Git in the app doesn't do push.pushOption." }
    if let submodules = settings.value("push.recurseSubmodules")?.lowercased(), submodules != "no" {
      return "Git in the app doesn't do push.recurseSubmodules \(submodules)."
    }
    for key in ["push", "receivepack", "proxy", "vcs"] where settings.value("remote.\(remote).\(key)") != nil {
      return "Git in the app doesn't do remote.\(remote).\(key)."
    }
    return nil
  }

  /// What every action has in common: the level's rules on addresses, then git when the app can't and may not, then
  /// the app, then git when the app turned out not to be able to.
  private func gate(
    _ names: [String], _ direction: Direction, obstacle: String?,
    body: ([String]) async throws -> GitNetworkOutcome
  ) async throws -> GitNetworkOutcome {
    var allowed = names
    var refusals: [String] = []
    if level >= .sshOnly { (allowed, refusals) = await enforce(names, direction) }
    let refusal = refusals.isEmpty ? nil : refusals.joined(separator: "\n\n")
    if allowed.isEmpty, let refusal { throw GitEngineError.refused(refusal) }
    let limited = refusal == nil ? nil : allowed
    if canUseGit, let reason = await obstacle.asyncOr({ await addressReason(allowed, direction) }) {
      return .useGit(reason: reason, remotes: limited, refusal: refusal)
    }
    if let obstacle { throw GitEngineError.refused("\(obstacle) \(level.title) refuses it.") }
    let outcome: GitNetworkOutcome
    do {
      outcome = try await body(allowed)
    } catch where canUseGit && GitEngineNetwork.gitMightDoBetter(error) {
      return .useGit(reason: "\(error)", remotes: limited, refusal: refusal)
    }
    if let refusal { throw GitEngineError.refused(refusal) }
    return outcome
  }

  private func urls(of remote: String, _ direction: Direction) throws -> [String] {
    direction == .fetch ? [try context.fetchURL(remote)] : try context.pushURLs(remote)
  }

  private func addressReason(_ names: [String], _ direction: Direction) async -> String? {
    for name in names {
      for url in (try? urls(of: name, direction)) ?? [] {
        if let reason = await SSHSetup.gitReason(url, settings: context.settings, request: request) {
          return "\(name): \(reason)"
        }
      }
    }
    return nil
  }

  /// `sshOnly` and `vaultKeyOnly`: which remotes may be used, and why the others may not.
  private func enforce(_ names: [String], _ direction: Direction) async -> (allowed: [String], refusals: [String]) {
    var allowed: [String] = []
    var refusals: [String] = []
    remotes: for name in names {
      if level == .sshOnly {
        do {
          try await RemoteMover(context: context).moveToSSH(name, progress: request.progress)
        } catch {
          refusals.append(
            "\(name) stays on HTTPS, which SSH only refuses: \(error.localizedDescription) Nothing was changed.")
          continue
        }
      }
      let urls: [String]
      do {
        urls = try self.urls(of: name, direction)
      } catch {
        refusals.append(error.localizedDescription)
        continue
      }
      for url in urls {
        if let refusal = await refusal(of: url, remote: name) {
          refusals.append(refusal)
          continue remotes
        }
      }
      allowed.append(name)
    }
    return (allowed, refusals)
  }

  private func refusal(of url: String, remote: String) async -> String? {
    await AddressRules.refusal(of: url, named: remote, request: request)
  }
}

/// What `sshOnly` and `vaultKeyOnly` say about an address.
enum AddressRules {
  static func refusal(of url: String, named name: String, request: GitNetworkRequest) async -> String? {
    let level = request.level
    switch RemoteAddress(url) {
    case .ssh(let address):
      guard level == .vaultKeyOnly, let alias = await SSHSetup.aliasReason(address, request) else { return nil }
      return "\(name): \(alias) Vault key only doesn’t read that config: use the server’s real address."
    case .https, .unencrypted:
      return "\(name) uses \(url), and \(level.title) only signs in over SSH. Use its SSH address."
    case .local:
      return level == .vaultKeyOnly ? "\(name) is a folder on this machine (\(url)), which Vault key only doesn’t reach." : nil
    case .helper:
      return "\(name) goes through a helper (\(url)), which \(level.title) doesn’t run."
    }
  }
}

extension Optional where Wrapped == String {
  fileprivate func asyncOr(_ other: () async -> String?) async -> String? {
    if let self { return self }
    return await other()
  }
}

/// A clone: no repository yet, only the address.
private struct CloneRoute {
  let request: GitNetworkRequest

  private var level: GitSecurityLevel { request.level }
  private var canUseGit: Bool { request.hasGit && level < .vaultKeyOnly }

  func run(_ remote: String, to destination: URL) async throws -> GitNetworkOutcome {
    var address = remote
    if level == .sshOnly, let ssh = SSHRemote(httpsURL: remote) {
      do {
        try await RemoteMover.check(ssh.url)
      } catch {
        throw GitEngineError.refused(
          "\(remote) is HTTPS, which SSH only refuses, and \(ssh.url) didn’t work: \(error.localizedDescription)")
      }
      address = ssh.url
    }
    if level >= .sshOnly, let refusal = await AddressRules.refusal(of: address, named: "The address", request: request) {
      throw GitEngineError.refused(refusal)
    }
    let settings = GitConfig(settings: request.settings ?? [])
    if canUseGit {
      if settings.value("init.templateDir") != nil { return .useGit(reason: "init.templateDir is set.", url: address) }
      if let reason = await SSHSetup.gitReason(address, settings: settings, request: request) {
        return .useGit(reason: reason, url: address)
      }
    }
    do {
      let repository = try await LocalRepository.clone(
        from: address, to: destination, settings: request.settings, checksOut: !request.hasGit, progress: request.progress)
      // git's checkout would have git-lfs download the files over its own connection, with the user's credentials.
      if level == .vaultKeyOnly, request.hasGit, try RepositoryChecks(context: repository.context()).headUsesLFS {
        try? FileManager.default.removeItem(at: destination)
        throw GitEngineError.refused(
          "This repository uses Git LFS, whose files git-lfs downloads over its own connection. Vault key only can’t clone it.")
      }
      return request.hasGit ? .fetched : .done
    } catch where canUseGit && GitEngineNetwork.gitMightDoBetter(error) {
      return .useGit(reason: "\(error)", url: address)
    }
  }
}

/// `sshOnly` moving remotes to SSH, on the first network action that uses them, and back afterwards. The old address is
/// remembered in the remote's own config, where git leaves unknown keys alone.
struct RemoteMover {
  let context: GitContext

  /// Whether SSH works with this device's key: the server listing its refs is enough, and changes nothing.
  static func check(_ url: String) async throws {
    let uploadPack = try await UploadPack.connect(url)
    uploadPack.transport.close()
  }

  /// Moves what `remote` has on HTTP(S) to the same repository over SSH, once SSH was seen to work there; throws
  /// without changing anything otherwise.
  func moveToSSH(_ remote: String, progress: (@Sendable (String) -> Void)?) async throws {
    let settings = context.settings
    let urlKey = "remote.\(remote).url", pushKey = "remote.\(remote).pushurl"
    let rawURLs = settings.values(urlKey)
    let rawPushURLs = settings.values(pushKey)
    // What it's reached at, after `insteadOf`: a short name can stand for an HTTPS address.
    let effectiveURL = try context.fetchURL(remote)
    let effectivePush = rawPushURLs.isEmpty ? [] : try context.pushURLs(remote)
    func target(_ url: String) throws -> String? {
      switch RemoteAddress(url) {
      case .https, .unencrypted:
        guard let ssh = SSHRemote(httpsURL: url) else {
          throw GitEngineError.refused("Git can’t tell the SSH address of \(url).")
        }
        return ssh.url
      default: return nil
      }
    }
    let newURL = try target(effectiveURL)
    let newPush = try effectivePush.map(target)
    guard newURL != nil || newPush.contains(where: { $0 != nil }) else { return }
    guard rawURLs.count <= 1 else { throw GitEngineError.refused("\(remote) has several addresses.") }
    for url in Set(([newURL] + newPush).compactMap { $0 }).sorted() {
      progress?("Checking \(url)…")
      try await Self.check(url)
    }
    try context.updateConfig { config in
      if let newURL, let old = rawURLs.first {
        try config.set("remote.\(remote).v57-https-url", old)
        try config.set("remote.\(remote).v57-ssh-url", newURL)
        try config.set(urlKey, newURL)
      }
      if newPush.contains(where: { $0 != nil }) {
        try config.set("remote.\(remote).v57-https-pushurl", nil)
        for old in rawPushURLs { try config.add("remote.\(remote).v57-https-pushurl", old) }
        try config.set(pushKey, nil)
        for (old, new) in zip(rawPushURLs, newPush) { try config.add(pushKey, new ?? old) }
      }
    }
    progress?("Moved \(remote) to SSH.")
  }

  /// Puts every moved remote back, unless its address was changed since, and forgets what was remembered.
  func restore() {
    let config = context.config
    for remote in config.subsections(of: "remote") {
      let oldURL = config.value("remote.\(remote).v57-https-url")
      let oldPush = config.values("remote.\(remote).v57-https-pushurl")
      guard oldURL != nil || !oldPush.isEmpty else { continue }
      try? context.updateConfig { config in
        if let oldURL, config.value("remote.\(remote).url") == config.value("remote.\(remote).v57-ssh-url") {
          try config.set("remote.\(remote).url", oldURL)
        }
        let current = config.values("remote.\(remote).pushurl")
        if !oldPush.isEmpty, current.count == oldPush.count {
          try config.set("remote.\(remote).pushurl", nil)
          for (old, now) in zip(oldPush, current) {
            // One that wasn't HTTP(S), or was changed since, stays.
            let moved = SSHRemote(httpsURL: old)?.url == now
            try config.add("remote.\(remote).pushurl", moved ? old : now)
          }
        }
        for key in ["v57-https-url", "v57-ssh-url", "v57-https-pushurl"] { try config.set("remote.\(remote).\(key)", nil) }
      }
    }
  }
}

/// What in a repository the engine can't do, read from its files.
struct RepositoryChecks {
  let context: GitContext

  private var fileManager: FileManager { .default }

  private func exists(_ path: String) -> Bool {
    fileManager.fileExists(atPath: context.commonDirectory.appendingPathComponent(path).path)
  }

  /// Why the engine can't work in this repository's format; nil when it can.
  var format: String? {
    let config = context.settings
    if let version = config.value("core.repositoryformatversion").flatMap(Int.init), version > 1 {
      return "This repository's format (version \(version)) is newer than Git in the app reads."
    }
    for name in config.names(in: "extensions") {
      switch name {
      case "objectformat":
        if config.value("extensions.objectformat")?.lowercased() != "sha1" {
          return "This repository uses SHA-256 object IDs, which Git in the app doesn't read yet."
        }
      case "refstorage":
        if config.value("extensions.refstorage")?.lowercased() != "files" {
          return "This repository keeps its refs in a reftable, which Git in the app doesn't read yet."
        }
      case "partialclone": return "This is a partial clone, which Git in the app doesn't do."
      case "worktreeconfig", "noop", "noop-v1": continue
      default: return "This repository uses extensions.\(name), which Git in the app doesn't know."
      }
    }
    if config.subsections(of: "remote").contains(where: { config.bool("remote.\($0).promisor", default: false) }) {
      return "This is a partial clone, which Git in the app doesn't do."
    }
    if exists("shallow") { return "This is a shallow clone, which Git in the app doesn't do." }
    if exists("objects/info/alternates") { return "This repository borrows objects from another (alternates)." }
    return nil
  }

  /// Whether a `name` hook would run: an executable file in `core.hooksPath` or the repository's hooks folder.
  func hasHook(_ name: String) -> Bool {
    let folder: URL
    if let path = context.settings.value("core.hooksPath") {
      let expanded = (path as NSString).expandingTildeInPath
      folder = expanded.hasPrefix("/") ? URL(fileURLWithPath: expanded) : context.worktree.appendingPathComponent(expanded)
    } else {
      folder = context.commonDirectory.appendingPathComponent("hooks")
    }
    return fileManager.isExecutableFile(atPath: folder.appendingPathComponent(name).path)
  }

  /// Whether files here go through Git LFS: git-lfs has been at work, or `.gitattributes` send paths to its filter.
  var usesLFS: Bool {
    if exists("lfs") { return true }
    var files = [
      context.worktree.appendingPathComponent(".gitattributes"),
      context.commonDirectory.appendingPathComponent("info/attributes"),
    ]
    let tracked = (try? context.readIndex().entries.map(\.path)) ?? []
    files += tracked.filter { $0.hasSuffix("/.gitattributes") }.map { context.worktree.appendingPathComponent($0) }
    return files.contains { (try? String(contentsOf: $0, encoding: .utf8)).map(Self.namesLFS) ?? false }
  }

  /// The same for what HEAD has, before anything is checked out.
  var headUsesLFS: Bool {
    get throws {
      try context.headFiles().contains { path, file in
        guard path == ".gitattributes" || path.hasSuffix("/.gitattributes") else { return false }
        return Self.namesLFS(String(decoding: try context.objects.read(file.id).data, as: UTF8.self))
      }
    }
  }

  private static func namesLFS(_ attributes: String) -> Bool { attributes.contains("filter=lfs") }

  /// Whether submodules were set up here, which `git fetch` then keeps fetching.
  var hasSubmodules: Bool {
    let modules = context.commonDirectory.appendingPathComponent("modules").path
    return !((try? fileManager.contentsOfDirectory(atPath: modules))?.isEmpty ?? true)
  }
}
