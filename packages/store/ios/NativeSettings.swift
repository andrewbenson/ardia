public import SolaraStore

extension NativeStore {
  @MainActor private static var model: SettingsModel?

  @MainActor public static var settingsModel: SettingsModel? {
    if let model { return model }
    guard let store = shared?.bridge.store else { return nil }
    let made = SettingsModel(store: store)
    model = made
    return made
  }
}
