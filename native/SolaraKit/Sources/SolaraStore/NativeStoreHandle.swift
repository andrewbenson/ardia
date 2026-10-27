public enum NativeStoreHandle {
  @MainActor public static var resolve: (() -> Store?)?

  @MainActor public static var store: Store? { resolve?() }
}
