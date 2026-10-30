import Foundation
import SolaraStore
import SolaraUI

@MainActor
enum NativeOmniboxSources {
  static let shared = OmniboxWorkspaceFeed(
    sources: .shared,
    ownsWorkspace: { NativeStoreHandle.ownsWorkspace },
    resolve: { NativeStoreHandle.store })
}
