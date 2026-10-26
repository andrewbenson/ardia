import AppKit
import ArdiaShell
import Foundation
import SolaraModel
import SolaraStore
import SolaraUI
import SwiftUI

@MainActor
final class StoreSettingsSource: SettingsStoreSource {
  let model: SettingsModel

  init(model: SettingsModel) {
    self.model = model
  }

  func settingValue(_ key: String) -> JSONValue? { model.value(key) }

  func updateSettings(_ patch: JSONObject) { model.update(patch) }

  var profiles: [SolaraUI.SettingsProfile] {
    model.profiles.map { SolaraUI.SettingsProfile(id: $0.id, name: $0.name, engineProfile: $0.engineProfile) }
  }

  var topTabLayout: Bool { model.value("tabLayout")?.string == "top" }

  func chooseTabLayout(_ layout: String) {
    SettingsJS.shared.fire("tabs.chooseLayout", layout)
  }
}

@MainActor
enum NativeSettingsWindow {
  static let windowId = "settings"
  private static var context: SettingsContext?

  nonisolated static var enabled: Bool {
    ProcessInfo.processInfo.environment["ARDIA_NATIVE_SETTINGS"] != "0" && NativeSettingsHandle.active
  }

  static func install() {
    WindowHost.makeAuxController = { id, kind in
      guard kind == "settings", enabled, let context = makeContext() else { return nil }
      let controller = NSHostingController(rootView: SettingsWindowView(context: context))
      controller.sceneBridgingOptions = [.toolbars]
      return controller
    }
  }

  static func makeContext() -> SettingsContext? {
    if let context { return context }
    guard let model = NativeSettingsHandle.model else { return nil }
    let store = StoreSettingsSource(model: model)
    let made = SettingsContext(appName: Bundle.main.productName, liquidGlass: liquidGlass, store: store)
    made.favicons = SettingsFavicons(displayHost: SettingsAdapters.displayHost) { url, profile in await SettingsAdapters.favicon(url: url, profile: profile) }
    made.profileForPane = { pane, current in
      guard pane == .extensions else { return nil }
      if current.pane == .extensions, let profile = current.profileId { return profile }
      return SettingsJS.shared.latestValue("extensions.defaultProfile") as? String
    }
    made.onPaneChange = { pane in SettingsJS.shared.fire("settings.paneShown", pane.rawValue) }
    SettingsAdapters.register(made, store: store)
    context = made
    return made
  }

  static var liquidGlass: Bool {
    if #available(macOS 26.0, *) { return true }
    return false
  }

  static func navigate(pane: String?, profileId: String?, detail: String?) {
    guard let context = makeContext(), let pane, let target = SettingsPane(rawValue: pane) else { return }
    context.navigation.go(target, profileId: profileId, detail: detail)
  }

  static func focusSearch() {
    makeContext()?.search.requestFocus()
  }
}
