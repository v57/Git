import CoreServices
import Foundation

/// Watches a working tree and its `.git` directory with FSEvents and calls `onChange` (on a
/// background queue) after changes settle. Object writes and lock files are ignored, so git's own
/// bookkeeping doesn't trigger refresh loops.
public final class RepositoryWatcher: @unchecked Sendable {
  private let paths: [String]
  private let onChange: @Sendable ([String]) -> Void
  private let queue = DispatchQueue(label: "dev.v57.GitKit.watcher")
  private var stream: FSEventStreamRef?

  public convenience init(
    paths: [URL], latency: TimeInterval = 0.4, onChange: @escaping @Sendable () -> Void
  ) {
    self.init(paths: paths, latency: latency, onChanges: { _ in onChange() })
  }

  /// Calls `onChanges` with the relevant paths that changed, so one watcher can serve several
  /// repositories.
  public init(
    paths: [URL], latency: TimeInterval = 0.4, onChanges: @escaping @Sendable ([String]) -> Void
  ) {
    self.paths = Array(Set(paths.map { $0.standardizedFileURL.path }))
    self.onChange = onChanges
    self.latency = latency
    queue.setSpecific(key: Self.queueKey, value: ())
  }

  private let latency: TimeInterval

  deinit { stop() }

  public func start() {
    queue.sync {
      guard stream == nil else { return }
      var context = FSEventStreamContext(
        version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil,
        copyDescription: nil)
      let callback: FSEventStreamCallback = { _, info, count, paths, _, _ in
        guard let info else { return }
        let watcher = Unmanaged<RepositoryWatcher>.fromOpaque(info).takeUnretainedValue()
        let array = Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue() as? [String] ?? []
        watcher.handle(array.prefix(count))
      }
      let flags = UInt32(
        kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents
          | kFSEventStreamCreateFlagNoDefer)
      guard
        let stream = FSEventStreamCreate(
          kCFAllocatorDefault, callback, &context, paths as CFArray,
          FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency, flags)
      else { return }
      FSEventStreamSetDispatchQueue(stream, queue)
      FSEventStreamStart(stream)
      self.stream = stream
    }
  }

  public func stop() {
    let stop = { [self] in
      guard let stream else { return }
      FSEventStreamStop(stream)
      FSEventStreamInvalidate(stream)
      FSEventStreamRelease(stream)
      self.stream = nil
    }
    if DispatchQueue.getSpecific(key: Self.queueKey) != nil { stop() } else { queue.sync(execute: stop) }
  }

  private static let queueKey = DispatchSpecificKey<Void>()

  private func handle(_ changed: ArraySlice<String>) {
    let relevant = changed.filter(Self.isRelevant)
    if !relevant.isEmpty { onChange(Array(relevant)) }
  }

  static func isRelevant(_ path: String) -> Bool {
    if path.hasSuffix(".lock") { return false }
    if let range = path.range(of: "/.git/") {
      let inside = path[range.upperBound...]
      // Refs, HEAD and the index matter; objects, logs and hooks don't.
      return !(inside.hasPrefix("objects") || inside.hasPrefix("logs") || inside.hasPrefix("hooks")
        || inside.hasPrefix("lfs") || inside.hasPrefix("modules") || inside.hasPrefix("fsmonitor"))
    }
    return true
  }
}
