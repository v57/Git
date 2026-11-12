import ComponentKit
import GitKit
import SwiftUI

/// What `counted` counts.
enum CountedNoun { case commit, file, changedLine }

/// Counts as a menu says them ("1 commit", "3 files").
func counted(_ count: Int, _ noun: CountedNoun) -> String {
  switch noun {
  case .commit: String(localized: "\(count) commits")
  case .file: String(localized: "\(count) files")
  case .changedLine: String(localized: "\(count) changed lines")
  }
}

extension View {
  /// A Merge row's end ("2 commits", "Up to date") and its sentence and picture: `git merge` adds a merge commit
  /// unless `into` can just move forward.
  func mergePreview(_ branch: Branch, into current: String) -> some View {
    let ahead = branch.aheadOfHead
    let commits = ahead.map { String(localized: "the \(counted($0, .commit)) from \(branch.name)") }
      ?? String(localized: "the commits from \(branch.name)")
    let fastForward = branch.behindHead == 0
    let sentence =
      ahead == 0
      ? String(localized: "\(current) already has every commit on \(branch.name).")
      : fastForward
        ? String(localized: "Moves \(current) forward by \(commits). No merge commit is needed.")
        : String(localized: "Adds \(commits) to \(current) with a merge commit.")
    return
      self
      .kitMenuHint(ahead.map { $0 == 0 ? String(localized: "Up to date") : counted($0, .commit) })
      .kitMenuPreview(sentence) {
        BranchPicture(.merge(commits: ahead, from: branch.name, into: current, fastForward: fastForward))
      }
  }
}

/// The small drawing above a menu row's sentence (`.kitMenuPreview("…") { BranchPicture(…) }`): what the row does to a
/// branch, in dots and lines. Dots stand for commits (a few at most, however many there are); the words under them
/// carry the real counts where the menu knows them. Drawn on a 252 × 44 grid, stretched to the panel's width.
struct BranchPicture: View {
  enum Kind {
    /// Pull: `incoming` commits join the line before `yours`; `source` is the remote ("origin"), when known.
    case pull(incoming: Int, yours: Int, branch: String, source: String?)
    /// Merge `from` into `into`: a side line joining back with a merge commit, or, `fastForward`, the line running on.
    case merge(commits: Int?, from: String, into: String, fastForward: Bool)
    /// Squash: `commits` hollow dots become one.
    case squash(commits: Int)
    /// Force push: your commits replace the remote's, and the remote's `lost` commits (as last fetched) go.
    case forcePush(yours: Int, lost: Int, remote: String)
    /// Reset: `branch` moves back to a commit, the later ones leave it.
    case reset(branch: String)
  }

  let kind: Kind
  init(_ kind: Kind) { self.kind = kind }

  private static let width: CGFloat = 252
  private static let height: CGFloat = 44

  var body: some View {
    GeometryReader { proxy in
      let scale = proxy.size.width / Self.width
      ZStack(alignment: .topLeading) {
        ForEach(Array(marks.enumerated()), id: \.offset) { _, mark in
          draw(mark, scale: scale)
        }
      }
    }
    .frame(height: Self.height)
    .frame(maxWidth: Self.width)
    .accessibilityHidden(true)
  }

  // MARK: The marks

  private enum Tone {
    case secondary, tertiary, accent, red, label

    var style: AnyShapeStyle {
      switch self {
      case .secondary: AnyShapeStyle(.kitSecondary)
      case .tertiary: AnyShapeStyle(.kitTertiary)
      case .accent: AnyShapeStyle(.kitAccent)
      case .red: AnyShapeStyle(Hue.red.text)
      case .label: AnyShapeStyle(.kitLabel)
      }
    }
  }

  private enum Anchor { case start, middle }

  private enum Mark {
    case dot(x: CGFloat, y: CGFloat, tone: Tone, hollow: Bool)
    /// Straight runs and curves: points, with `curve` making each pair after the first a cubic's end and controls.
    case path([Segment], tone: Tone, dashed: Bool)
    /// `y` is the text's baseline, as in the canvas's SVG.
    case word(String, x: CGFloat, y: CGFloat, tone: Tone, anchor: Anchor, weight: Font.Weight)
  }

  private enum Segment {
    case move(CGFloat, CGFloat)
    case line(CGFloat, CGFloat)
    case curve(to: (CGFloat, CGFloat), c1: (CGFloat, CGFloat), c2: (CGFloat, CGFloat))
  }

  private static func dot(_ x: CGFloat, _ y: CGFloat = 18, _ tone: Tone = .secondary, hollow: Bool = false) -> Mark {
    .dot(x: x, y: y, tone: tone, hollow: hollow)
  }

  private static func line(_ a: CGFloat, _ b: CGFloat, y: CGFloat = 18, _ tone: Tone = .tertiary, dashed: Bool = false)
    -> Mark
  {
    .path([.move(a, y), .line(b, y)], tone: tone, dashed: dashed)
  }

  private static func word(
    _ text: String, _ x: CGFloat, _ y: CGFloat, _ tone: Tone = .secondary, _ anchor: Anchor = .middle,
    weight: Font.Weight = .regular
  ) -> Mark {
    .word(text, x: x, y: y, tone: tone, anchor: anchor, weight: weight)
  }

  /// `count` positions from `start`, `step` apart.
  private static func run(_ count: Int, from start: CGFloat, step: CGFloat = 24) -> [CGFloat] {
    (0..<count).map { start + CGFloat($0) * step }
  }

  private var marks: [Mark] {
    switch kind {
    case .pull(let incoming, let yours, let branch, let source):
      let new = Self.run(min(max(incoming, 1), 3), from: 66)
      let own = Self.run(min(yours, 2), from: (new.last ?? 66) + 32)
      let end = own.last ?? new.last ?? 66
      var marks: [Mark] = [Self.line(10, end), Self.dot(10), Self.dot(36)]
      marks += new.map { Self.dot($0, 18, .accent) } + own.map { Self.dot($0) }
      let words = incoming > 0 ? (source.map { "\(incoming) from \($0)" } ?? "\(incoming) new") : "new"
      marks.append(Self.word(words, (new[0] + new[new.count - 1]) / 2, 36, .accent, weight: .medium))
      if let first = own.first, let last = own.last { marks.append(Self.word("yours", (first + last) / 2, 36)) }
      marks.append(Self.word(branch, end + 8, 21, .label, .start, weight: .semibold))
      return marks

    case .merge(let commits, let from, let into, let fastForward):
      let count = min(max(commits ?? 2, 1), 3)
      if fastForward {
        let new = Self.run(count, from: 66)
        let end = new.last ?? 66
        return [Self.line(10, end), Self.dot(10), Self.dot(36)] + new.map { Self.dot($0, 18, .accent) } + [
          Self.word(from, (new[0] + end) / 2, 36, .accent, weight: .medium),
          Self.word(into, end + 8, 21, .label, .start, weight: .semibold),
        ]
      }
      let side: [CGFloat] = count == 1 ? [116] : count == 2 ? [100, 132] : [92, 116, 140]
      return [
        Self.line(10, 196, y: 10), Self.dot(10, 10), Self.dot(50, 10), Self.dot(196, 10, .accent),
        .path(
          [
            .move(50, 10), .curve(to: (82, 28), c1: (66, 10), c2: (66, 28)), .line(150, 28),
            .curve(to: (196, 10), c1: (172, 28), c2: (174, 10)),
          ], tone: .accent, dashed: false),
      ] + side.map { Self.dot($0, 28, .accent) } + [
        Self.word(from, 116, 42, .accent, weight: .medium),
        Self.word(into, 204, 13, .label, .start, weight: .semibold),
      ]

    case .squash(let commits):
      let old = Self.run(min(max(commits, 2), 3), from: 70, step: 28)
      return [Self.line(10, old.last ?? 126), Self.dot(10), Self.dot(36)]
        + old.map { Self.dot($0, 18, .accent, hollow: true) } + [
          .path([.move(144, 18), .line(168, 18), .move(163, 13), .line(168, 18), .line(163, 23)], tone: .accent, dashed: false),
          Self.dot(184, 18, .accent),
          Self.word(counted(commits, .commit), (old[0] + old[old.count - 1]) / 2, 36, .accent, weight: .medium),
          Self.word("1 commit", 184, 36, .accent, weight: .medium),
        ]

    case .forcePush(let yours, let lost, let remote):
      var marks: [Mark] = [
        Self.line(10, 48, y: 20), Self.dot(10, 20), Self.dot(48, 20),
        .path([.move(48, 20), .curve(to: (76, 9), c1: (62, 20), c2: (62, 9)), .line(124, 9)], tone: .accent, dashed: false),
      ]
      marks += (yours > 1 ? [88.0, 120] : [104.0]).map { Self.dot($0, 9, .accent) }
      marks.append(Self.word("yours, now on \(remote)", 134, 12, .accent, .start, weight: .medium))
      if lost > 0 {
        marks.append(
          .path([.move(48, 20), .curve(to: (76, 32), c1: (62, 20), c2: (62, 32)), .line(124, 32)], tone: .tertiary, dashed: true))
        marks += (lost > 1 ? [88.0, 120] : [104.0]).map { Self.dot($0, 32, .red, hollow: true) }
        marks.append(Self.word("gone from \(remote)", 134, 35, .red, .start))
      }
      return marks

    case .reset(let branch):
      return [
        Self.line(10, 90), Self.line(90, 206, dashed: true), Self.dot(10), Self.dot(50), Self.dot(90, 18, .accent),
        Self.dot(148, 18, .red, hollow: true), Self.dot(206, 18, .red, hollow: true),
        Self.word("\(branch) moves here", 90, 36, .accent, weight: .medium),
        Self.word("leave \(branch)", 177, 36, .red),
      ]
    }
  }

  // MARK: Drawing

  @ViewBuilder
  private func draw(_ mark: Mark, scale: CGFloat) -> some View {
    switch mark {
    case .dot(let x, let y, let tone, let hollow):
      if hollow {
        Circle()
          .stroke(tone.style, style: StrokeStyle(lineWidth: 1.2, dash: [2, 1.6]))
          .frame(width: 7, height: 7)
          .position(x: x * scale, y: y)
      } else {
        Circle().fill(tone.style).frame(width: 8, height: 8).position(x: x * scale, y: y)
      }
    case .path(let segments, let tone, let dashed):
      Path { path in
        for segment in segments {
          switch segment {
          case .move(let x, let y): path.move(to: CGPoint(x: x * scale, y: y))
          case .line(let x, let y): path.addLine(to: CGPoint(x: x * scale, y: y))
          case .curve(let to, let c1, let c2):
            path.addCurve(
              to: CGPoint(x: to.0 * scale, y: to.1), control1: CGPoint(x: c1.0 * scale, y: c1.1),
              control2: CGPoint(x: c2.0 * scale, y: c2.1))
          }
        }
      }
      .stroke(tone.style, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round, dash: dashed ? [3, 3] : []))
    case .word(let text, let x, let y, let tone, let anchor, let weight):
      // From the SVG's baseline to the 10pt line's middle.
      let middle = y - 3.5
      switch anchor {
      case .middle:
        Text(text).font(.system(size: 10, weight: weight)).foregroundStyle(tone.style).lineLimit(1).fixedSize()
          .position(x: x * scale, y: middle)
      case .start:
        // Up to the drawing's end, cut there.
        let room = max(Self.width * scale - x * scale, 0)
        Text(text).font(.system(size: 10, weight: weight)).foregroundStyle(tone.style).lineLimit(1)
          .truncationMode(.middle)
          .frame(width: room, alignment: .leading)
          .position(x: x * scale + room / 2, y: middle)
      }
    }
  }
}
