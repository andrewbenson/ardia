import Foundation

public enum NativeSettingsHandle {
  nonisolated(unsafe) public static var active = false
  @MainActor public static var resolve: (() -> SettingsModel?)?

  @MainActor public static var model: SettingsModel? { resolve?() }
}
