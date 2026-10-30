import SolaraEngine
import SolaraStore

@MainActor
enum NativeHistoryHints {
  private static var lifecycle: Int?
  private static var provider: HistoryHintsProvider?
  private static weak var boundStore: Store?

  static func start(catalog: LibraryCatalog) {
    guard lifecycle == nil else { return }
    lifecycle = NativeStoreHandle.subscribeLifecycle {
      guard NativeStoreHandle.ownsWorkspace, let store = NativeStoreHandle.store else {
        provider?.stop()
        provider = nil
        boundStore = nil
        return
      }
      guard boundStore !== store else { return }
      provider?.stop()
      boundStore = store
      let next = HistoryHintsProvider(catalog: catalog, store: store)
      provider = next
      next.start()
    }
  }
}
