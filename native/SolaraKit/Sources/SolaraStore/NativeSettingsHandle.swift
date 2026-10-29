import Foundation

public enum NativeSettingsHandle {
  nonisolated(unsafe) public static var active = false
  nonisolated(unsafe) public static var unavailable: StoreUnavailable?
  @MainActor public static var resolve: (() -> SettingsModel?)?

  @MainActor public static var model: SettingsModel? { resolve?() }
}
