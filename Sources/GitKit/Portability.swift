// Off Apple platforms the Foundation APIs swift-corelibs-foundation lacks (moving to the trash) come from
// v57/SwiftUI's portability module.
#if !canImport(ObjectiveC) && canImport(SwiftUIPortability)
  import SwiftUIPortability
#endif
