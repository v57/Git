import Foundation

/// What `lstat` says about a working-tree file, in the 32-bit fields the index keeps.
struct FileStat: Equatable {
  var ctimeSeconds: UInt32 = 0
  var ctimeNanoseconds: UInt32 = 0
  var mtimeSeconds: UInt32 = 0
  var mtimeNanoseconds: UInt32 = 0
  var device: UInt32 = 0
  var inode: UInt32 = 0
  var uid: UInt32 = 0
  var gid: UInt32 = 0
  var size: UInt32 = 0
  /// The raw `st_mode`.
  var mode: UInt32 = 0

  static func of(_ path: String) -> FileStat? {
    var info = stat()
    guard lstat(path, &info) == 0 else { return nil }
    return FileStat(
      ctimeSeconds: UInt32(truncatingIfNeeded: info.st_ctimespec.tv_sec),
      ctimeNanoseconds: UInt32(truncatingIfNeeded: info.st_ctimespec.tv_nsec),
      mtimeSeconds: UInt32(truncatingIfNeeded: info.st_mtimespec.tv_sec),
      mtimeNanoseconds: UInt32(truncatingIfNeeded: info.st_mtimespec.tv_nsec),
      device: UInt32(truncatingIfNeeded: info.st_dev), inode: UInt32(truncatingIfNeeded: info.st_ino),
      uid: info.st_uid, gid: info.st_gid, size: UInt32(truncatingIfNeeded: info.st_size),
      mode: UInt32(info.st_mode))
  }

  var isDirectory: Bool { mode & UInt32(S_IFMT) == UInt32(S_IFDIR) }
  var isSymlink: Bool { mode & UInt32(S_IFMT) == UInt32(S_IFLNK) }
  var isRegular: Bool { mode & UInt32(S_IFMT) == UInt32(S_IFREG) }
  var isExecutable: Bool { mode & 0o100 != 0 }

  /// The mode git would record for this file.
  func fileMode(trustExecutableBit: Bool, previous: FileMode?) -> FileMode {
    if isSymlink { return .symlink }
    if isDirectory { return .gitlink }
    if !trustExecutableBit, let previous, previous.isFile { return previous }
    return isExecutable ? .executable : .regular
  }

  /// Seconds and nanoseconds as one comparable number.
  var mtime: UInt64 { UInt64(mtimeSeconds) << 32 | UInt64(mtimeNanoseconds) }
}
