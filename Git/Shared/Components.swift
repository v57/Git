import AppKit
import ComponentKit
import GitKit
import SwiftUI

/// The git branch glyph from the design: two commits on a line and a branch curving off.
struct BranchGlyph: View {
  var size: CGFloat = 16

  var body: some View {
    Canvas { context, canvas in
      let s = canvas.width / 16
      var path = Path()
      path.addEllipse(in: CGRect(x: 3.5 * s, y: 2 * s, width: 3 * s, height: 3 * s))
      path.addEllipse(in: CGRect(x: 3.5 * s, y: 11 * s, width: 3 * s, height: 3 * s))
      path.addEllipse(in: CGRect(x: 9.5 * s, y: 3.5 * s, width: 3 * s, height: 3 * s))
      path.move(to: CGPoint(x: 5 * s, y: 5 * s))
      path.addLine(to: CGPoint(x: 5 * s, y: 11 * s))
      path.move(to: CGPoint(x: 11 * s, y: 6.5 * s))
      path.addCurve(
        to: CGPoint(x: 5 * s, y: 11 * s), control1: CGPoint(x: 11 * s, y: 9.5 * s),
        control2: CGPoint(x: 5 * s, y: 9 * s))
      context.stroke(
        path, with: .style(.foreground),
        style: StrokeStyle(lineWidth: 1.4 * s, lineCap: .round, lineJoin: .round))
    }
    .frame(width: size, height: size)
    .accessibilityHidden(true)
  }
}

/// A file's status letter on a tinted tile: M, A, D, R, U…
struct ChangeKindBadge: View {
  let kind: ChangeKind
  var size: CGFloat = 18

  var body: some View {
    Tile(letters: kind == .untracked ? "A" : kind.letter, hue: hue, size: size)
      .help(Self.name(kind))
      .accessibilityElement()
      .accessibilityLabel(Self.name(kind))
  }

  static func name(_ kind: ChangeKind) -> String {
    switch kind {
    case .added: "Added"
    case .modified: "Modified"
    case .deleted: "Deleted"
    case .renamed: "Renamed"
    case .copied: "Copied"
    case .typeChanged: "Type changed"
    case .untracked: "New file"
    case .conflicted: "Conflicted"
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

extension Date {
  /// "Today, 10:42", "Yesterday, 18:03" or "Oct 8, 17:20".
  var historyFormatted: String {
    let calendar = Calendar.current
    // Follows the system's 12/24-hour setting.
    let time = formatted(.dateTime.hour(.defaultDigits(amPM: .abbreviated)).minute(.twoDigits))
    if calendar.isDateInToday(self) { return "Today, \(time)" }
    if calendar.isDateInYesterday(self) { return "Yesterday, \(time)" }
    if calendar.isDate(self, equalTo: .now, toGranularity: .year) {
      return "\(formatted(.dateTime.month(.abbreviated).day())), \(time)"
    }
    return formatted(.dateTime.year().month(.abbreviated).day())
  }

  /// "just now", "3 min ago", "2 hr ago" or "4 days ago".
  var agoFormatted: String {
    let seconds = Int(-timeIntervalSinceNow)
    if seconds < 60 { return "just now" }
    if seconds < 3600 { return "\(seconds / 60) min ago" }
    if seconds < 86_400 { return "\(seconds / 3600) hr ago" }
    let days = seconds / 86_400
    return days == 1 ? "1 day ago" : "\(days) days ago"
  }

  /// "Today", "Yesterday" or "Oct 8".
  var dayFormatted: String {
    let calendar = Calendar.current
    if calendar.isDateInToday(self) { return "Today" }
    if calendar.isDateInYesterday(self) { return "Yesterday" }
    return formatted(.dateTime.month(.abbreviated).day())
  }
}

func copyToPasteboard(_ string: String) {
  NSPasteboard.general.clearContents()
  NSPasteboard.general.setString(string, forType: .string)
}
