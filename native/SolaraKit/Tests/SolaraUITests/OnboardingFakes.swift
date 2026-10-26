import AppKit
import Foundation
import SolaraModel
@testable import SolaraUI

@MainActor
final class OnboardingFakeStore: SettingsStoreSource {
  var settings = Settings.defaults
  var patches: [JSONObject] = []
  var profiles: [SettingsProfile] = [SettingsProfile(id: "default", name: "Personal", engineProfile: "default")]
  var topTabLayout: Bool { settings.string("tabLayout") == "top" }

  func settingValue(_ key: String) -> JSONValue? { settings[key] }

  func updateSettings(_ patch: JSONObject) {
    patches.append(patch)
    settings = settings.updated(patch, fromSync: false)
  }

  func chooseTabLayout(_ layout: String) { updateSettings(["tabLayout": .string(layout)]) }
}

@MainActor
final class OnboardingFakeServices: OnboardingServices {
  let store: OnboardingFakeStore
  var document: String?
  var session = false
  var startsOnFirstLaunch = true
  var clock = 1_790_000_000_000.0
  var windowLayout: [String: String] = [:]
  var previews: [JSONObject] = []
  var colors: [String: ProfileColorValue] = ["w1": .plum]
  var incognito = false
  var tourEnded = 0
  var toursStarted: [String] = []
  var music: [String] = []
  var installed: Set<String> = ["/Applications/Arc.app", "/Applications/Safari.app", "/Applications/Brave Browser Beta.app"]
  var importAvailable = true
  var imports: [String] = []
  var backgroundInstance = false
  var isDefault = false
  var inDock = false
  var login: LoginItemStatus = .notRegistered
  var setDefaultResult = true
  var setDefaultCalls = 0
  var loginCalls: [Bool] = []
  var dockCalls = 0
  var icons: [OnboardingAppIcon] = [OnboardingAppIcon(id: "default", name: "Default", preview: nil), OnboardingAppIcon(id: "night", name: "Night", preview: nil)]
  var current: String? = "default"
  var iconSet: [String] = []
  var pinned: Set<String> = []
  var visits: [OnboardingHistoryVisit] = []
  var opened: [[String]] = []

  init(store: OnboardingFakeStore) {
    self.store = store
  }

  func readOnboardingDocument() -> String? { document }
  func writeOnboardingDocument(_ json: String) { document = json }
  func hasSessionDocument() -> Bool { session }
  func now() -> Double { clock }
  func resolveWindowId(_ windowId: String?) -> String? { windowId ?? "w1" }
  func windowTabLayout(_ windowId: String?) -> String { windowLayout[windowId ?? ""] ?? store.settings.string("tabLayout") ?? "sidebar" }
  func setWindowTabLayout(_ windowId: String, _ layout: String) { windowLayout[windowId] = layout }
  func previewSettings(_ patch: JSONObject) {
    previews.append(patch)
    store.settings = store.settings.updated(patch, fromSync: true)
  }
  func profileColor(_ windowId: String) -> ProfileColorValue? { colors[windowId] }
  func isIncognito(_ windowId: String) -> Bool { incognito }
  func setProfileColor(_ windowId: String, _ color: ProfileColorValue) { colors[windowId] = color }
  func endToolTour() { tourEnded += 1 }
  func startToolTour(_ windowId: String) { toursStarted.append(windowId) }
  func playIntroMusic(_ cues: IntroMusicCues, muted: Bool) { music.append("play \(muted)") }
  func setIntroMusicMuted(_ muted: Bool) { music.append("mute \(muted)") }
  func stopIntroMusic(fade: Double) { music.append("stop \(fade)") }
  func fileExists(_ path: String) -> Bool { installed.contains(path) }
  func fileIcon(_ path: String, size: Int) async -> NSImage? { nil }
  func openImport(_ browserId: String) { imports.append(browserId) }
  func isDefaultBrowser() async -> Bool { isDefault }
  func isInDock() async -> Bool { inDock }
  func loginItemStatus() async -> LoginItemStatus { login }
  func setAsDefaultBrowser() async -> Bool {
    setDefaultCalls += 1
    return setDefaultResult
  }
  func setLaunchAtLogin(_ on: Bool) async { loginCalls.append(on) }
  func addToDock() async { dockCalls += 1 }
  func appIcons(size: Int) async -> [OnboardingAppIcon] { icons }
  func currentAppIcon() async -> String? { current }
  func setAppIcon(_ id: String) async { iconSet.append(id) }
  func pinnedHosts(_ windowId: String) -> Set<String> { pinned }
  func history(_ windowId: String) -> [OnboardingHistoryVisit] { visits }
  func openPinnedTabs(_ windowId: String, _ sites: [PinnableSite]) { opened.append(sites.map(\.id)) }
  func favicon(_ url: String) async -> NSImage? { nil }
}

@MainActor
final class OnboardingFakeDiagnostics: DiagnosticsSharingServices {
  var available = true
  var sharing = false
  var sources: [String] = []
  var telemetryHost = "telemetry.solara.example"
  let updateHost = "updates.solara.example"
  let switchFile = "updates.solara.example/switches.json"

  func setSharing(_ on: Bool, source: String) {
    sharing = on
    sources.append(source)
  }
}

@MainActor
enum OnboardingFixture {
  static func make(diagnostics available: Bool = true) -> (OnboardingModel, OnboardingFakeServices, OnboardingFakeStore, OnboardingFakeDiagnostics) {
    let store = OnboardingFakeStore()
    let services = OnboardingFakeServices(store: store)
    let diagnostics = OnboardingFakeDiagnostics()
    diagnostics.available = available
    let model = OnboardingModel(services: services, store: store, diagnostics: diagnostics, appName: "Solara")
    return (model, services, store, diagnostics)
  }

  static func saved(_ services: OnboardingFakeServices) -> JSONObject {
    (try? JSONValue.parse(services.document ?? "{}"))?.object ?? [:]
  }
}
