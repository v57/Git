import ComponentKit
import SwiftUI

/// How signing in to GitHub is going, as `GitHubConnectionView` draws it.
public enum GitHubConnectionPhase: Hashable, Sendable {
  case idle, waiting, connected, failed
}

/// The app's and GitHub's tiles joined by a line that shows how signing in is going: dashes while idle; marching
/// dashes, a dot travelling to GitHub and a pulsing ring while waiting; a green line drawing across with a check once
/// connected; an orange "!" that shakes on failure.
///
/// ```swift
/// GitHubConnectionView(phase: .idle, tileSize: 52) { BranchGlyph() }
/// GitHubConnectionView(phase: .waiting, systemImage: "doc.text")
/// ```
public struct GitHubConnectionView<Glyph: View>: View {
  let phase: GitHubConnectionPhase
  let tileSize: CGFloat
  @ViewBuilder let glyph: Glyph

  /// - Parameter glyph: the app's glyph on its accent tile, white; it can size itself from `kitGlyphSize`.
  public init(phase: GitHubConnectionPhase, tileSize: CGFloat = 48, @ViewBuilder glyph: () -> Glyph) {
    self.phase = phase
    self.tileSize = tileSize
    self.glyph = glyph()
  }

  public var body: some View {
    HStack(spacing: 12) {
      AppTile(size: tileSize) { glyph }
      ZStack {
        switch phase {
        case .idle: DashedLine(style: AnyShapeStyle(.kitTertiary))
        case .waiting: WaitingLine()
        case .connected: ConnectedLine()
        case .failed: FailedLine()
        }
      }
      .id(phase)
      .transition(.opacity)
      .frame(width: tileSize * 2, height: 24)
      GitHubTile(size: tileSize, isPulsing: phase == .waiting)
    }
    .animation(.kit, value: phase)
    .accessibilityHidden(true)
  }
}

extension GitHubConnectionView where Glyph == Image {
  /// The app's tile with an SF Symbol.
  public init(phase: GitHubConnectionPhase, tileSize: CGFloat = 48, systemImage: String) {
    self.init(phase: phase, tileSize: tileSize) { Image(systemName: systemImage) }
  }
}

/// The app's tile: its glyph on the accent.
private struct AppTile<Glyph: View>: View {
  let size: CGFloat
  @ViewBuilder let glyph: Glyph

  var body: some View {
    let shape = RoundedRectangle(cornerRadius: size * 0.25, style: .continuous)
    glyph
      .font(.system(size: size * 0.42, weight: .medium))
      .environment(\.kitGlyphSize, size * 0.54)
      .foregroundStyle(.white)
      .frame(width: size, height: size)
      // The accent as a gradient, lighter at the top.
      .background {
        shape.fill(.kitAccent)
          .overlay(shape.fill(LinearGradient(colors: [.white.opacity(0.16), .clear], startPoint: .top, endPoint: .bottom)))
      }
      .shadow(color: .black.opacity(0.12), radius: 6, y: 4)
  }
}

/// GitHub's tile: a cloud on near-black, with a ring that pulses outward while waiting.
private struct GitHubTile: View {
  let size: CGFloat
  var isPulsing = false
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    let shape = RoundedRectangle(cornerRadius: size * 0.25, style: .continuous)
    Image(systemName: "cloud")
      .font(.system(size: size * 0.42, weight: .medium))
      .foregroundStyle(.white)
      .frame(width: size, height: size)
      .background(Color(white: 0.12), in: shape)
      .overlay(shape.strokeBorder(.white.opacity(0.12)))
      .shadow(color: .black.opacity(0.12), radius: 6, y: 4)
      .background {
        if isPulsing && !reduceMotion {
          TimelineView(.animation) { context in
            let progress = context.date.timeIntervalSinceReferenceDate
              .truncatingRemainder(dividingBy: 1.6) / 1.6
            shape.stroke(.kitAccent, lineWidth: 2)
              .scaleEffect(1 + 0.5 * progress)
              .opacity(0.5 * (1 - progress))
          }
        }
      }
  }
}

private struct DashedLine: View {
  let style: AnyShapeStyle
  var phase: CGFloat = 0

  var body: some View {
    LineShape()
      .stroke(style, style: StrokeStyle(lineWidth: 2, lineCap: .butt, dash: [6, 6], dashPhase: phase))
      .frame(height: 2)
  }
}

/// Marching dashes and a dot easing from the app to GitHub, over and over.
private struct WaitingLine: View {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    TimelineView(.animation(paused: reduceMotion)) { context in
      let time = context.date.timeIntervalSinceReferenceDate
      let progress = time.truncatingRemainder(dividingBy: 1.5) / 1.5
      let eased = progress < 0.5 ? 2 * progress * progress : 1 - pow(-2 * progress + 2, 2) / 2
      let fade = min(1, min(progress, 1 - progress) / 0.12)
      GeometryReader { proxy in
        ZStack(alignment: .leading) {
          DashedLine(
            style: AnyShapeStyle(Hue.accent.soft(0.45)), phase: -(time * 20).truncatingRemainder(dividingBy: 12))
          Circle()
            .fill(.kitAccent)
            .frame(width: 8, height: 8)
            .background(Circle().fill(Hue.accent.soft(0.18)).padding(-3))
            .offset(x: eased * (proxy.size.width - 8))
            .opacity(reduceMotion ? 0 : fade)
        }
        .frame(maxHeight: .infinity)
      }
    }
  }
}

/// A green line drawing itself across, then a check badge popping in and drawing its tick.
private struct ConnectedLine: View {
  @State private var drawn = false
  @State private var badge = false
  @State private var tick = false

  var body: some View {
    ZStack {
      LineShape()
        .trim(from: 0, to: drawn ? 1 : 0)
        .stroke(Hue.green.fill, style: StrokeStyle(lineWidth: 2, lineCap: .round))
        .frame(height: 2)
      CheckShape()
        .trim(from: 0, to: tick ? 1 : 0)
        .stroke(.white, style: StrokeStyle(lineWidth: 2.4, lineCap: .round, lineJoin: .round))
        .frame(width: 12, height: 12)
        .frame(width: 24, height: 24)
        .background(Circle().fill(Hue.green.fill))
        .background(Circle().fill(.kitWindow).padding(-4))
        .scaleEffect(badge ? 1 : 0.3)
        .opacity(badge ? 1 : 0)
    }
    .onAppear {
      withAnimation(.smooth(duration: 0.45)) { drawn = true }
      withAnimation(.spring(response: 0.4, dampingFraction: 0.55).delay(0.3)) { badge = true }
      withAnimation(.easeOut(duration: 0.35).delay(0.6)) { tick = true }
    }
  }
}

/// Grey dashes and an orange "!" that pops in, then shakes.
private struct FailedLine: View {
  @State private var shown = false
  @State private var shakes = 0

  var body: some View {
    ZStack {
      DashedLine(style: AnyShapeStyle(.kitTertiary))
      Image(systemName: "exclamationmark")
        .kitFont(.headline)
        .fontWeight(.heavy)
        .foregroundStyle(.white)
        .frame(width: 24, height: 24)
        .background(Circle().fill(Hue.orange.fill))
        .background(Circle().fill(.kitWindow).padding(-4))
        .scaleEffect(shown ? 1 : 0.3)
        .opacity(shown ? 1 : 0)
        .keyframeAnimator(initialValue: 0.0, trigger: shakes) { content, offset in
          content.offset(x: offset)
        } keyframes: { _ in
          KeyframeTrack {
            CubicKeyframe(-6, duration: 0.09)
            CubicKeyframe(6, duration: 0.09)
            CubicKeyframe(-3, duration: 0.09)
            CubicKeyframe(3, duration: 0.09)
            CubicKeyframe(0, duration: 0.09)
          }
        }
    }
    .task {
      withAnimation(.spring(response: 0.4, dampingFraction: 0.55)) { shown = true }
      try? await Task.sleep(for: .milliseconds(400))
      shakes += 1
    }
  }
}

nonisolated private struct LineShape: Shape {
  func path(in rect: CGRect) -> Path {
    Path { path in
      path.move(to: CGPoint(x: rect.minX, y: rect.midY))
      path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
    }
  }
}

/// A tick, drawn left to right so trimming animates it like a pen stroke.
nonisolated private struct CheckShape: Shape {
  func path(in rect: CGRect) -> Path {
    Path { path in
      path.move(to: CGPoint(x: rect.minX, y: rect.minY + rect.height * 0.55))
      path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.38, y: rect.maxY - rect.height * 0.1))
      path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + rect.height * 0.12))
    }
  }
}
