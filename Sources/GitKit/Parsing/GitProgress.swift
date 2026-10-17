import Foundation

/// Reads git's `--progress` lines.
public enum GitProgress {
  /// The share done (0…1) of a transfer line, "Receiving objects:  45% (450/1000), 1.2 MiB | 2 MiB/s" or
  /// "Writing objects:  33% (1/3)"; `nil` for the other phases (counting, compressing, resolving), which are short
  /// and would start the share over.
  public static func fraction(of line: String) -> Double? {
    guard line.hasPrefix("Receiving objects:") || line.hasPrefix("Writing objects:"),
      let percent = line.firstMatch(of: #/(\d{1,3})%/#)?.1, let value = Double(percent)
    else { return nil }
    return min(value, 100) / 100
  }
}
