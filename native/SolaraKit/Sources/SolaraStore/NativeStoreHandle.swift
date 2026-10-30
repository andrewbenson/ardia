public enum NativeStoreHandle {
  nonisolated(unsafe) public static var opened = false
  nonisolated(unsafe) public static var ownedWorkspaceAtLaunch = false
  @MainActor public static var ownsWorkspace = false {
    didSet {
      guard ownsWorkspace != oldValue else { return }
      if !ownsWorkspace { ownershipGeneration += 1 }
      notifyLifecycle()
    }
  }

  @MainActor public private(set) static var ownershipGeneration = 0

  @MainActor public static var resolve: (() -> Store?)? {
    didSet { notifyLifecycle() }
  }

  @MainActor private static var lifecycleListeners: [Int: () -> Void] = [:]
  @MainActor private static var nextLifecycleListener = 0

  @MainActor public static var store: Store? { resolve?() }

  @MainActor public static func subscribeLifecycle(_ listener: @escaping () -> Void) -> Int {
    nextLifecycleListener += 1
    let id = nextLifecycleListener
    lifecycleListeners[id] = listener
    listener()
    return id
  }

  @MainActor public static func unsubscribeLifecycle(_ id: Int) {
    lifecycleListeners.removeValue(forKey: id)
  }

  @MainActor private static func notifyLifecycle() {
    for listener in Array(lifecycleListeners.values) { listener() }
  }
}
