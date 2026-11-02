#if os(iOS)
  import GitMobileApp
#else
  import GitApp
#endif
import SwiftUI

/// The app for the platform being built: the package's conditions link only that one, so the entry point and the Xcode
/// project have one thing to link.
public enum GitEntry {
  public static func main() { GitApp.main() }
}
