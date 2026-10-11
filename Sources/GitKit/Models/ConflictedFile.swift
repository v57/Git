import Foundation

/// How the two sides of a conflicted path disagree (the `XY` of a `u` status record).
public enum ConflictType: String, Sendable, Hashable {
  case bothModified, bothAdded, bothDeleted, addedByUs, addedByThem, deletedByUs, deletedByThem

  init?(xy: Substring) {
    switch xy {
    case "UU": self = .bothModified
    case "AA": self = .bothAdded
    case "DD": self = .bothDeleted
    case "AU": self = .addedByUs
    case "UA": self = .addedByThem
    case "DU": self = .deletedByUs
    case "UD": self = .deletedByThem
    default: return nil
    }
  }

  public var title: String {
    switch self {
    case .bothModified: "Changed on both sides"
    case .bothAdded: "Added on both sides"
    case .bothDeleted: "Deleted on both sides"
    case .addedByUs: "Added on the current branch"
    case .addedByThem: "Added by the incoming change"
    case .deletedByUs: "Deleted on the current branch, changed by the incoming change"
    case .deletedByThem: "Changed on the current branch, deleted by the incoming change"
    }
  }

  /// One side deleted the file, so resolving means keeping or deleting it.
  public var involvesDeletion: Bool {
    self == .bothDeleted || self == .deletedByUs || self == .deletedByThem
  }
}

/// Which side of a conflict to keep.
public enum ConflictSide: String, Sendable, Hashable {
  /// The current branch (`HEAD`, "ours").
  case current
  /// The branch or commit being merged, picked or replayed ("theirs").
  case incoming
}

/// How to resolve one conflict block.
public enum ConflictResolution: String, Sendable, Hashable, CaseIterable {
  case current, incoming, currentThenIncoming, incomingThenCurrent
}

/// One `<<<<<<<` … `>>>>>>>` block of a conflicted file.
public struct ConflictBlock: Sendable, Hashable, Identifiable {
  /// The block's position among the file's blocks, from 0.
  public var id: Int
  /// The current side's lines, each with its line ending.
  public var current: String
  /// The common ancestor's lines, present with `merge.conflictStyle` diff3 or zdiff3.
  public var base: String?
  public var incoming: String
  /// The text after `<<<<<<<` and `>>>>>>>`, e.g. `HEAD` and `feature`.
  public var currentLabel: String
  public var incomingLabel: String
  /// The 1-based line of the `<<<<<<<` marker.
  public var line: Int

  public init(
    id: Int, current: String, base: String? = nil, incoming: String, currentLabel: String = "",
    incomingLabel: String = "", line: Int = 1
  ) {
    self.id = id
    self.current = current
    self.base = base
    self.incoming = incoming
    self.currentLabel = currentLabel
    self.incomingLabel = incomingLabel
    self.line = line
  }

  public func text(for resolution: ConflictResolution) -> String {
    switch resolution {
    case .current: current
    case .incoming: incoming
    case .currentThenIncoming: Self.join(current, incoming)
    case .incomingThenCurrent: Self.join(incoming, current)
    }
  }

  /// `first` then `second`, with a line break between them when `first` lacks one.
  private static func join(_ first: String, _ second: String) -> String {
    guard !first.isEmpty, !second.isEmpty, first.last?.isNewline != true else { return first + second }
    return first + "\n" + second
  }
}

/// A conflicted file's text: the parts both sides agree on and the blocks git marked.
public struct ConflictedFile: Sendable, Hashable {
  public enum Segment: Sendable, Hashable {
    case common(String)
    case conflict(ConflictBlock)
  }

  public var segments: [Segment]

  public init(segments: [Segment]) {
    self.segments = segments
  }

  public var blocks: [ConflictBlock] {
    segments.compactMap {
      if case .conflict(let block) = $0 { block } else { nil }
    }
  }

  /// The file with every block replaced by its resolution, or `nil` while a block has none.
  public func resolved(_ resolutions: [Int: ConflictResolution]) -> String? {
    var text = ""
    for segment in segments {
      switch segment {
      case .common(let common):
        text += common
      case .conflict(let block):
        guard let resolution = resolutions[block.id] else { return nil }
        text += block.text(for: resolution)
      }
    }
    return text
  }
}

/// Splits a file with conflict markers into a `ConflictedFile`.
public enum ConflictParser {
  /// `nil` when the text has no complete conflict block.
  public static func parse(_ text: String) -> ConflictedFile? {
    enum Part { case common, current, base, incoming }

    var segments: [ConflictedFile.Segment] = []
    var part = Part.common
    var common = "", current = "", base: String?, incoming = ""
    var currentLabel = "", markerLine = 0
    var blockCount = 0

    for (index, line) in lines(of: text).enumerated() {
      switch part {
      case .common:
        if let label = marker("<<<<<<<", line) {
          if !common.isEmpty { segments.append(.common(common)) }
          common = ""
          current = ""
          base = nil
          incoming = ""
          currentLabel = label
          markerLine = index + 1
          part = .current
        } else {
          common += line
        }
      case .current:
        if marker("|||||||", line) != nil {
          base = ""
          part = .base
        } else if isSeparator(line) {
          part = .incoming
        } else if marker("<<<<<<<", line) != nil {
          return nil
        } else {
          current += line
        }
      case .base:
        if isSeparator(line) { part = .incoming } else { base! += line }
      case .incoming:
        if let label = marker(">>>>>>>", line) {
          segments.append(
            .conflict(
              ConflictBlock(
                id: blockCount, current: current, base: base, incoming: incoming,
                currentLabel: currentLabel, incomingLabel: label, line: markerLine)))
          blockCount += 1
          part = .common
        } else if marker("<<<<<<<", line) != nil {
          return nil
        } else {
          incoming += line
        }
      }
    }
    guard part == .common, blockCount > 0 else { return nil }
    if !common.isEmpty { segments.append(.common(common)) }
    return ConflictedFile(segments: segments)
  }

  /// The lines of `text`, each keeping its line ending. (`\r\n` is a single `Character`.)
  public static func lines(of text: String) -> [Substring] {
    var lines: [Substring] = []
    var start = text.startIndex
    while start < text.endIndex {
      if let newline = text[start...].firstIndex(where: { $0 == "\n" || $0 == "\r\n" }) {
        let end = text.index(after: newline)
        lines.append(text[start..<end])
        start = end
      } else {
        lines.append(text[start...])
        break
      }
    }
    return lines
  }

  /// The label after a marker such as `<<<<<<< HEAD`, or `nil` when `line` isn't that marker.
  private static func marker(_ marker: String, _ line: Substring) -> String? {
    guard line.hasPrefix(marker) else { return nil }
    let rest = line.dropFirst(marker.count)
    guard rest.isEmpty || rest.first == " " || rest.first?.isNewline == true else {
      return nil
    }
    return rest.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private static func isSeparator(_ line: Substring) -> Bool {
    line.trimmingCharacters(in: .newlines) == "======="
  }
}
