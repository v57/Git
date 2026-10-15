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

/// A circle with a person's initials, in a color picked from their name.
struct Avatar: View {
  let name: String
  let size: CGFloat

  private static let palette: [Color] = [.purple, .orange, .blue, .teal, .pink, .indigo, .green, .brown]

  var body: some View {
    Text(initials)
      .font(.system(size: size * 0.4, weight: .bold))
      .foregroundStyle(.white)
      .frame(width: size, height: size)
      .background(StableColor.pick(name, from: Self.palette).gradient, in: .circle)
      .accessibilityHidden(true)
  }

  private var initials: String {
    let words = name.split(whereSeparator: { $0 == " " || $0 == "." || $0 == "-" })
    let letters = words.prefix(2).compactMap(\.first).map { String($0).uppercased() }
    return letters.isEmpty ? "?" : letters.joined()
  }
}

/// A rounded square with a repository's initial, in a color picked from its name.
struct RepositoryIcon: View {
  let name: String
  let size: CGFloat

  private static let palette: [Color] = [.blue, .purple, .teal, .orange, .pink, .indigo, .green, .brown]

  var body: some View {
    Text(name.first.map { String($0).uppercased() } ?? "?")
      .font(.system(size: size * 0.55, weight: .bold, design: .rounded))
      .foregroundStyle(.white)
      .frame(width: size, height: size)
      .background(
        StableColor.pick(name, from: Self.palette).gradient,
        in: .rect(cornerRadius: size * 0.28, style: .continuous)
      )
      .accessibilityHidden(true)
  }
}

enum StableColor {
  /// A color that stays the same for `key` across launches (unlike `hashValue`).
  static func pick(_ key: String, from palette: [Color]) -> Color {
    let hash = key.unicodeScalars.reduce(UInt32(5381)) { ($0 &* 33) &+ $1.value }
    return palette[Int(hash % UInt32(palette.count))]
  }
}

/// A file's status letter on a tinted tile: M, A, D, R, U…
struct ChangeKindBadge: View {
  let kind: ChangeKind
  var size: CGFloat = 18

  var body: some View {
    Text(kind == .untracked ? "A" : kind.letter)
      .font(.system(size: size * 0.56, weight: .bold))
      .foregroundStyle(color)
      .frame(width: size, height: size)
      .background(color.opacity(0.16), in: .rect(cornerRadius: size * 0.28, style: .continuous))
      .help(Self.name(kind))
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

  private var color: Color {
    switch kind {
    case .added, .untracked: .green
    case .modified, .typeChanged: .blue
    case .deleted: .red
    case .renamed, .copied: .teal
    case .conflicted: .purple
    }
  }
}

/// "+12 −3" in green and red, monospaced.
struct LineCountText: View {
  let counts: GitKit.LineCounts?
  var font: Font = .system(size: 11, design: .monospaced)

  var body: some View {
    if let counts, let added = counts.added, let removed = counts.removed {
      HStack(spacing: 6) {
        Text("+\(added)").foregroundStyle(.green)
          .contentTransition(.numericText(value: Double(added)))
        Text("−\(removed)").foregroundStyle(.red)
          .contentTransition(.numericText(value: Double(removed)))
      }
      .font(font)
      .animation(.kit, value: counts)
      .accessibilityLabel("\(added) lines added, \(removed) removed")
    } else if counts != nil {
      Text("binary")
        .font(.caption)
        .foregroundStyle(.secondary)
    }
  }
}

/// A branch, tag or remote label on a commit.
struct RefPill: View {
  let ref: RefLabel
  var height: CGFloat = 18
  /// Shortens the name to the offered width instead of always showing all of it.
  var truncates = false

  var body: some View {
    Text(title)
      .font(.system(size: 11, weight: .semibold))
      .lineLimit(1)
      .padding(.horizontal, 7)
      .frame(height: height)
      .foregroundStyle(foreground)
      .background(background, in: .capsule)
      .overlay {
        if ref.kind == .remoteBranch { Capsule().strokeBorder(.separator) }
      }
      .fixedSize(horizontal: !truncates, vertical: true)
      .help(ref.name)
  }

  private var title: String { ref.isCurrent && ref.kind != .head ? "HEAD → \(ref.name)" : ref.name }

  private var foreground: Color {
    switch ref.kind {
    case .head, .localBranch: ref.isCurrent ? .white : .orange
    case .remoteBranch: .secondary
    case .tag, .other: .primary
    }
  }

  private var background: Color {
    switch ref.kind {
    case .head, .localBranch: ref.isCurrent ? Color.accentColor : Color.orange.opacity(0.16)
    case .remoteBranch: .clear
    case .tag, .other: Color.primary.opacity(0.08)
    }
  }
}

/// A commit's refs in the width they're offered: the ones that don't fit collapse into a “+N”
/// pill. When not even the first fits, it's shortened while `minShortenedWidth` of it fits, so the
/// row still names one ref; with less room only the count is left.
struct RefPills: View {
  let refs: [RefLabel]
  var height: CGFloat = 18
  var minShortenedWidth: CGFloat = 72

  var body: some View {
    if let first = refs.first {
      ViewThatFits(in: .horizontal) {
        ForEach(Array(stride(from: refs.count, through: 1, by: -1)), id: \.self) { shown in
          HStack(spacing: 6) {
            ForEach(refs.prefix(shown), id: \.self) { ref in RefPill(ref: ref, height: height) }
            more(after: shown)
          }
        }
        // ViewThatFits measures ideal widths, so the shortened pill offers its minimum as one.
        HStack(spacing: 6) {
          RefPill(ref: first, height: height, truncates: true)
            .frame(idealWidth: minShortenedWidth)
          more(after: 1)
        }
        more(after: 0)
      }
    }
  }

  @ViewBuilder
  private func more(after shown: Int) -> some View {
    if shown < refs.count {
      MoreRefsPill(refs: Array(refs.dropFirst(shown)), height: height)
    }
  }
}

/// The refs a row has no room for, as a count; the tooltip names them.
private struct MoreRefsPill: View {
  let refs: [RefLabel]
  let height: CGFloat

  var body: some View {
    Text("+\(refs.count)")
      .font(.system(size: 11, weight: .semibold))
      .padding(.horizontal, 7)
      .frame(height: height)
      .background(Color.primary.opacity(0.08), in: .capsule)
      .fixedSize()
      .help(refs.map(\.name).joined(separator: "\n"))
      .accessibilityLabel("\(refs.count) more: \(refs.map(\.name).joined(separator: ", "))")
  }
}

/// A sidebar or list section title: small, semibold, secondary.
struct SectionTitle: View {
  let title: String

  init(_ title: String) { self.title = title }

  var body: some View {
    Text(title)
      .font(.system(size: 11, weight: .semibold))
      .foregroundStyle(.secondary)
  }
}

/// A count in a small capsule.
struct CountBadge: View {
  let count: Int
  var filled: Color?

  var body: some View {
    Text("\(count)")
      .font(.system(size: 11, weight: filled == nil ? .semibold : .bold).monospacedDigit())
      .contentTransition(.numericText(value: Double(count)))
      .animation(.kit, value: count)
      .foregroundStyle(filled == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.white))
      .padding(.horizontal, 6)
      .frame(minWidth: 20, minHeight: 18)
      .background(filled.map(AnyShapeStyle.init) ?? AnyShapeStyle(Color.primary.opacity(0.08)), in: .capsule)
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

// MARK: - Buttons

/// The design's buttons: a white bordered secondary button, an accent-filled primary one, and red
/// text for destructive actions, in three heights.
struct DesignButtonStyle: ButtonStyle {
  enum Kind { case secondary, primary, destructive }
  enum Size {
    /// 28 points, in cards and rows.
    case small
    /// 30 points, in headers and banners.
    case regular
    /// 34 points, the commit buttons.
    case large

    var height: CGFloat { self == .small ? 28 : self == .regular ? 30 : 34 }
    var radius: CGFloat { self == .small ? 7 : self == .regular ? 8 : 9 }
  }

  var kind: Kind = .secondary
  var size: Size = .regular
  /// Space on each side of the label; the commit hash button uses 8.
  var padding: CGFloat = 12

  func makeBody(configuration: Configuration) -> some View {
    DesignButton(configuration: configuration, kind: kind, size: size, padding: padding)
  }

  private struct DesignButton: View {
    let configuration: Configuration
    let kind: Kind
    let size: Size
    let padding: CGFloat
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false

    var body: some View {
      let shape = RoundedRectangle(cornerRadius: size.radius, style: .continuous)
      configuration.label
        .font(.system(size: 13, weight: kind == .primary ? .semibold : .medium))
        .lineLimit(1)
        .foregroundStyle(foreground)
        // The 1-point border sits inside the width, as in the design (border-box).
        .padding(.horizontal, padding + (kind == .primary ? 0 : 1))
        .frame(height: size.height)
        .background(background, in: shape)
        .overlay {
          if kind != .primary { shape.strokeBorder(Color.primary.opacity(0.16)) }
        }
        .overlay {
          // Hover and press darken the button a little.
          shape.fill(Color.primary.opacity(configuration.isPressed ? 0.1 : isHovered && isEnabled ? 0.04 : 0))
        }
        .shadow(color: .black.opacity(kind == .primary || !isEnabled ? 0 : 0.05), radius: 0.5, y: 1)
        .opacity(isEnabled || kind == .primary ? 1 : 0.45)
        .contentShape(shape)
        .onHover { isHovered = $0 }
        .animation(.kit, value: isHovered)
        .animation(.kit, value: isEnabled)
    }

    private var foreground: AnyShapeStyle {
      switch kind {
      case .primary: isEnabled ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary)
      case .destructive: AnyShapeStyle(Color.red)
      case .secondary: AnyShapeStyle(.primary)
      }
    }

    private var background: AnyShapeStyle {
      switch kind {
      case .primary: isEnabled ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(Color.primary.opacity(0.1))
      case .secondary, .destructive: AnyShapeStyle(Color(nsColor: .controlBackgroundColor))
      }
    }
  }
}

extension ButtonStyle where Self == DesignButtonStyle {
  static var design: DesignButtonStyle { DesignButtonStyle() }
  static func design(
    _ kind: DesignButtonStyle.Kind = .secondary, size: DesignButtonStyle.Size = .regular,
    padding: CGFloat = 12
  ) -> DesignButtonStyle {
    DesignButtonStyle(kind: kind, size: size, padding: padding)
  }
}

/// A box drawn like a secondary button, for menu labels (the ⋯ menu).
struct DesignButtonLabel<Content: View>: View {
  var size: DesignButtonStyle.Size = .regular
  var width: CGFloat?
  @ViewBuilder var content: () -> Content

  var body: some View {
    let shape = RoundedRectangle(cornerRadius: size.radius, style: .continuous)
    content()
      .font(.system(size: 13, weight: .medium))
      .frame(width: width, height: size.height)
      .padding(.horizontal, width == nil ? 13 : 0)
      .background(Color(nsColor: .controlBackgroundColor), in: shape)
      .overlay(shape.strokeBorder(Color.primary.opacity(0.16)))
      .shadow(color: .black.opacity(0.05), radius: 0.5, y: 1)
      .contentShape(shape)
  }
}

/// The design's segmented control: a gray track with the selected segment raised in white.
struct DesignSegmented<Value: Hashable>: View {
  @Binding var selection: Value
  let options: [(title: String, value: Value)]

  var body: some View {
    HStack(spacing: 0) {
      ForEach(options, id: \.value) { option in
        let isSelected = option.value == selection
        Button {
          withAnimation(.kit) { selection = option.value }
        } label: {
          Text(option.title)
            .font(.system(size: 12, weight: isSelected ? .medium : .regular))
            .foregroundStyle(isSelected ? .primary : .secondary)
            .padding(.horizontal, 12)
            .frame(height: 24)
            .background {
              if isSelected {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                  .fill(Color(nsColor: .controlBackgroundColor))
                  .shadow(color: .black.opacity(0.14), radius: 1, y: 1)
              }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
      }
    }
    .padding(2)
    .background(Color.primary.opacity(0.08), in: .rect(cornerRadius: 8, style: .continuous))
    .fixedSize()
  }
}
