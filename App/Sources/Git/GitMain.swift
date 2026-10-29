import GitApp
import SwiftUI

/// The Mac app's entry point, and the app's on Linux and Windows: the app itself is the GitApp library
/// (App/Sources/GitApp).
@main enum GitMain {
  static func main() { GitApp.main() }
}
