import SwiftUI

/// The main content and a pane beside it, split by a hairline divider that drags the pane's
/// width. The width is remembered under `autosaveName`; double-clicking the divider restores
/// the default. When the window is too narrow for both, the main content gives way down to
/// `mainMinWidth`, then the pane down to its minimum.
struct ResizableSplit<Main: View, Pane: View>: View {
  let edge: HorizontalEdge
  let defaultWidth: CGFloat
  let range: ClosedRange<CGFloat>
  let mainMinWidth: CGFloat
  @ViewBuilder let main: Main
  @ViewBuilder let pane: Pane
  @AppStorage private var width: Double
  /// The pane's laid-out width, which drags start from (it can be less than `width`).
  @State private var shownWidth: CGFloat = 0
  @State private var dragStart: CGFloat?

  init(
    _ autosaveName: String, pane edge: HorizontalEdge, width defaultWidth: CGFloat,
    range: ClosedRange<CGFloat>, mainMinWidth: CGFloat = 0,
    @ViewBuilder main: () -> Main, @ViewBuilder pane: () -> Pane
  ) {
    self.edge = edge
    self.defaultWidth = defaultWidth
    self.range = range
    self.mainMinWidth = mainMinWidth
    self.main = main()
    self.pane = pane()
    _width = AppStorage(wrappedValue: Double(defaultWidth), autosaveName)
  }

  var body: some View {
    HStack(spacing: 0) {
      if edge == .leading {
        sizedPane
        divider
        sizedMain
      } else {
        sizedMain
        divider
        sizedPane
      }
    }
  }

  private var sizedMain: some View {
    main.frame(minWidth: mainMinWidth, maxWidth: .infinity)
  }

  private var sizedPane: some View {
    pane
      .frame(minWidth: range.lowerBound, maxWidth: min(max(width, range.lowerBound), range.upperBound))
      .onGeometryChange(for: CGFloat.self, of: \.size.width) { shownWidth = $0 }
      .layoutPriority(1)
  }

  private var divider: some View {
    Divider()
      .overlay {
        Color.clear
          .frame(width: 9)
          .contentShape(Rectangle())
          .pointerStyle(.columnResize)
          .gesture(
            DragGesture(minimumDistance: 1, coordinateSpace: .global)
              .onChanged { drag in
                let start = dragStart ?? shownWidth
                dragStart = start
                let offset = edge == .leading ? drag.translation.width : -drag.translation.width
                width = min(max(start + offset, range.lowerBound), range.upperBound)
              }
              .onEnded { _ in dragStart = nil }
          )
          .onTapGesture(count: 2) { withAnimation(.app) { width = defaultWidth } }
          .accessibilityHidden(true)
      }
      // Above the views beside it, so the whole grab area takes the drag.
      .zIndex(1)
  }
}
