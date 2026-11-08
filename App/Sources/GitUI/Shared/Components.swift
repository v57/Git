import ComponentKit
import GitKit
import SwiftUI

/// A file's status letter on a tinted tile: M, A, D, R, U…
public struct ChangeKindBadge: View {
  public let kind: ChangeKind
  public var size: CGFloat = 18

  public init(kind: ChangeKind, size: CGFloat = 18) {
    self.kind = kind
    self.size = size
  }

  public var body: some View {
    Tile(letters: kind == .untracked ? "A" : kind.letter, hue: hue, size: size)
      .help(Self.name(kind))
      .accessibilityElement()
      .accessibilityLabel(Self.name(kind))
  }

  public static func name(_ kind: ChangeKind) -> String {
    switch kind {
    case .added: String(localized: "Added")
    case .modified: String(localized: "Modified")
    case .deleted: String(localized: "Deleted")
    case .renamed: String(localized: "Renamed")
    case .copied: String(localized: "Copied")
    case .typeChanged: String(localized: "Type changed")
    case .untracked: String(localized: "New file")
    case .conflicted: String(localized: "Conflicted")
    }
  }

  private var hue: Hue {
    switch kind {
    case .added, .untracked: .green
    case .modified, .typeChanged: .blue
    case .deleted: .red
    case .renamed, .copied: .teal
    case .conflicted: .purple
    }
  }
}
