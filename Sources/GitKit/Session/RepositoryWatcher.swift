#if os(macOS)
  import CoreServices
#elseif os(Windows)
  import WinSDK
#endif
import Foundation

/// Watches a working tree and its `.git` directory with FSEvents and calls `onChange` (on a
/// background queue) after changes settle. Object writes and lock files are ignored, so git's own
/// bookkeeping doesn't trigger refresh loops.
public final class RepositoryWatcher: @unchecked Sendable {
  private let paths: [String]
  private let onChange: @Sendable ([String]) -> Void
  private let queue = DispatchQueue(label: "dev.v57.GitKit.watcher")
  #if os(macOS)
    private var stream: FSEventStreamRef?
  #elseif !os(Windows)
    private var timer: DispatchSourceTimer?
  #endif

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

  #if os(Windows)
    /// One thread per path reads ReadDirectoryChangesW (the tree, recursively); changes gather for `latency` and
    /// are handed on together, as FSEvents does.
    private final class DirectoryReader: @unchecked Sendable {
      let handle: HANDLE
      init?(path: String) {
        let opened = path.withCString(encodedAs: UTF16.self) {
          CreateFileW(
            $0, DWORD(FILE_LIST_DIRECTORY), DWORD(FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE), nil,
            DWORD(OPEN_EXISTING), DWORD(FILE_FLAG_BACKUP_SEMANTICS), nil)
        }
        guard let opened, opened != INVALID_HANDLE_VALUE else { return nil }
        handle = opened
      }

      /// Blocks until something under the folder changes; nil once closed.
      func next() -> [String]? {
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        var returned: DWORD = 0
        let filter = DWORD(
          FILE_NOTIFY_CHANGE_FILE_NAME | FILE_NOTIFY_CHANGE_DIR_NAME | FILE_NOTIFY_CHANGE_LAST_WRITE
            | FILE_NOTIFY_CHANGE_SIZE)
        let ok = buffer.withUnsafeMutableBytes { raw in
          ReadDirectoryChangesW(handle, raw.baseAddress, DWORD(raw.count), true, filter, &returned, nil, nil)
        }
        guard ok else { return nil }
        guard returned > 0 else { return [] }  // overflow: something changed
        var names: [String] = []
        buffer.withUnsafeBytes { raw in
          var offset = 0
          while true {
            let next = Int(raw.load(fromByteOffset: offset, as: DWORD.self))
            let length = Int(raw.load(fromByteOffset: offset + 8, as: DWORD.self))
            let name = raw.baseAddress!.advanced(by: offset + 12).assumingMemoryBound(to: UInt16.self)
            names.append(String(decoding: UnsafeBufferPointer(start: name, count: length / 2), as: UTF16.self))
            if next == 0 { break }
            offset += next
          }
        }
        return names
      }

      func close() {
        CancelIoEx(handle, nil)
        CloseHandle(handle)
      }
    }

    private var readers: [DirectoryReader] = []
    private var pending: Set<String> = []
    private var flushScheduled = false

    public func start() {
      queue.sync {
        guard readers.isEmpty else { return }
        for root in paths {
          guard let reader = DirectoryReader(path: root) else { continue }
          readers.append(reader)
          let thread = Thread { [weak self] in
            while let names = reader.next() {
              let changed = names.isEmpty ? [root] : names.map { root + "/" + $0.replacingOccurrences(of: "\\", with: "/") }
              self?.collect(changed)
            }
          }
          thread.name = "GitKit.RepositoryWatcher"
          thread.start()
        }
      }
    }

    private func collect(_ changed: [String]) {
      queue.async { [self] in
        pending.formUnion(changed)
        guard !flushScheduled else { return }
        flushScheduled = true
        queue.asyncAfter(deadline: .now() + latency) { [self] in
          flushScheduled = false
          let changes = pending
          pending = []
          handle(ArraySlice(changes.sorted()))
        }
      }
    }

    public func stop() {
      let stop = { [self] in
        for reader in readers { reader.close() }
        readers = []
      }
      if DispatchQueue.getSpecific(key: Self.queueKey) != nil { stop() } else { queue.sync(execute: stop) }
    }
  #elseif os(macOS)
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
  #else
    /// Where there's no file system to watch (git runs on another machine), the working tree is checked every
    /// `latency`, which the caller sets to a few seconds: `onChanges` gets no paths.
    public func start() {
      queue.sync {
        guard timer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        let interval = max(latency, 2)
        timer.schedule(deadline: .now() + interval, repeating: interval)
        timer.setEventHandler { [onChange] in onChange([]) }
        timer.resume()
        self.timer = timer
      }
    }

    public func stop() {
      if DispatchQueue.getSpecific(key: Self.queueKey) != nil {
        timer?.cancel()
        timer = nil
      } else {
        queue.sync {
          timer?.cancel()
          timer = nil
        }
      }
    }
  #endif

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
