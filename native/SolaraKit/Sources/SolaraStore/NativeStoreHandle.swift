public enum NativeStoreHandle {
  nonisolated(unsafe) public static var opened = false

  @MainActor public static var resolve: (() -> Store?)?

  @MainActor public static var store: Store? { resolve?() }
}
