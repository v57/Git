import ComponentKit
import SwiftUI

/// What went wrong (or what an action found), over the window as a kit sheet, never a system alert: the title, the
/// message (selectable, as git's output often is), and the buttons, OK by default. Return presses the last button.
///
/// ```swift
/// .kitSheet(isPresented: $showsFailure) {
///   MessageSheet(failure.title, message: failure.message)
/// }
/// ```
public struct MessageSheet<Buttons: View>: View {
  let title: String
  let message: String
  var systemImage = "exclamationmark.triangle"
  var hue: Hue = .orange
  @ViewBuilder var buttons: Buttons

  public init(
    title: String, message: String, systemImage: String = "exclamationmark.triangle", hue: Hue = .orange,
    @ViewBuilder buttons: () -> Buttons
  ) {
    self.title = title
    self.message = message
    self.systemImage = systemImage
    self.hue = hue
    self.buttons = buttons()
  }

  public var body: some View {
    KitSheet(title: title, systemImage: systemImage, hue: hue, width: 420) {
      Text(message)
        .kitFont(.body)
        .textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 4)
    } footer: {
      buttons
    }
  }
}

extension MessageSheet where Buttons == MessageOKButton {
  public init(_ title: String, message: String, systemImage: String = "exclamationmark.triangle", hue: Hue = .orange) {
    self.init(title: title, message: message, systemImage: systemImage, hue: hue) { MessageOKButton() }
  }
}

/// The message's one button: closes the sheet, on Return and Escape.
public struct MessageOKButton: View {
  @Environment(\.kitDismiss) private var dismiss

  public init() {}

  public var body: some View {
    Button("OK") { dismiss() }
      .buttonStyle(.kitPrimary)
      .keyboardShortcut(.defaultAction)
  }
}
