import AppKit
import ArdiaShell
import Foundation
import SolaraModel
import SolaraStore
import SolaraUI

@MainActor
final class OnboardingAdapter: OnboardingServices {
  static let topic = "onboarding.window"
  static let document = "onboarding.json"

  let windowId: String
  let settings: SettingsModel
  var onWindowChange: (() -> Void)?
  private var window: [String: Any]
  private var observer: UUID?

  init(windowId: String, settings: SettingsModel) {
    self.windowId = windowId
    self.settings = settings
    window = Self.entry(SettingsJS.shared.latestValue(Self.topic), for: windowId) ?? [:]
    observer = SettingsJS.shared.observe(Self.topic) { [weak self] value in
      guard let self, let next = Self.entry(value, for: self.windowId) else { return }
      self.window = next
      self.onWindowChange?()
    }
  }

  func dispose() {
    if let observer { SettingsJS.shared.stopObserving(Self.topic, observer) }
    observer = nil
    onWindowChange = nil
  }

  static func entry(_ value: Any?, for windowId: String) -> [String: Any]? {
    guard let dict = value as? [String: Any], dict.string("windowId") == windowId else { return nil }
    return dict
  }

  var savedDocument: [String: Any]? {
    guard let text = readOnboardingDocument(), let data = text.data(using: .utf8) else { return nil }
    return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
  }

  func readOnboardingDocument() -> String? { DocumentStore.read(Self.document) }

  func writeOnboardingDocument(_ json: String) {
    do {
      try DocumentStore.write(Self.document, json)
    } catch {
      NSLog("[onboarding] couldn't save onboarding state: %@", String(describing: error))
    }
  }

  func hasSessionDocument() -> Bool { DocumentStore.read("session.json") != nil }

  var startsOnFirstLaunch: Bool {
    #if DEBUG
    return ProcessInfo.processInfo.environment["ARDIA_ONBOARDING"] == "1"
    #else
    return true
    #endif
  }

  func now() -> Double { (Date().timeIntervalSince1970 * 1000).rounded() }

  func resolveWindowId(_ windowId: String?) -> String? { windowId ?? self.windowId }

  func windowTabLayout(_ windowId: String?) -> String {
    if windowId ?? self.windowId == self.windowId, let layout = window.string("tabLayout") { return layout }
    return settings.value("tabLayout")?.string ?? "sidebar"
  }

  func setWindowTabLayout(_ windowId: String, _ layout: String) {
    if windowId == self.windowId { window["tabLayout"] = layout }
    Self.fire("onboarding.setWindowLayout", windowId, layout)
  }

  func previewSettings(_ patch: JSONObject) { settings.update(patch, fromSync: true) }

  func profileColor(_ windowId: String) -> ProfileColorValue? {
    guard windowId == self.windowId else { return nil }
    return window.string("color").flatMap(ProfileColorValue.init(rawValue:))
  }

  func isIncognito(_ windowId: String) -> Bool { windowId == self.windowId && window.bool("incognito") == true }

  func setProfileColor(_ windowId: String, _ color: ProfileColorValue) {
    if windowId == self.windowId { window["color"] = color.rawValue }
    Self.fire("onboarding.setProfileColor", windowId, color.rawValue)
  }

  func endToolTour() { Self.fire("onboarding.endToolTour") }

  func startToolTour(_ windowId: String) { Self.fire("onboarding.startToolTour", windowId) }

  func playIntroMusic(_ cues: IntroMusicCues, muted: Bool) {
    let arg: [String: Any] = [
      "icon": cues.icon, "letters": cues.letters, "letterStep": cues.letterStep, "letterCount": cues.letterCount,
      "tagline": cues.tagline, "exit": cues.exit, "end": cues.end,
    ]
    Self.fire("onboarding.playIntroMusic", arg, muted)
  }

  func setIntroMusicMuted(_ muted: Bool) { Self.fire("onboarding.setIntroMusicMuted", muted) }

  func stopIntroMusic(fade: Double) { Self.fire("onboarding.stopIntroMusic", fade) }

  func fileExists(_ path: String) -> Bool { FileManager.default.fileExists(atPath: path) }

  func fileIcon(_ path: String, size: Int) async -> NSImage? {
    let icon = FileManager.default.fileExists(atPath: path)
      ? NSWorkspace.shared.icon(forFile: path)
      : NSWorkspace.shared.icon(for: .init(filenameExtension: (path as NSString).pathExtension) ?? .data)
    icon.size = NSSize(width: size, height: size)
    return icon
  }

  var importAvailable: Bool { window.bool("importAvailable") ?? false }

  func openImport(_ browserId: String) { Self.fire("onboarding.openImport", browserId) }

  var backgroundInstance: Bool { ProcessInfo.processInfo.environment["ARDIA_BACKGROUND"] == "1" }

  func isDefaultBrowser() async -> Bool { await Self.call("general.isDefaultBrowser") as? Bool ?? false }

  func isInDock() async -> Bool { await Self.call("onboarding.isInDock") as? Bool ?? false }

  func loginItemStatus() async -> LoginItemStatus {
    (await Self.call("general.loginItemStatus") as? String).flatMap(LoginItemStatus.init(rawValue:)) ?? .notRegistered
  }

  func setAsDefaultBrowser() async -> Bool { await Self.call("general.setAsDefaultBrowser") as? Bool ?? false }

  func setLaunchAtLogin(_ on: Bool) async { await Self.call("general.setLaunchAtLogin", on) }

  func addToDock() async { await Self.call("onboarding.addToDock") }

  func appIcons(size: Int) async -> [OnboardingAppIcon] {
    let result = await Self.call("appearance.appIcons", Double(size)) as? [String: Any] ?? [:]
    return result.list("icons").compactMap { icon in
      guard let id = icon.string("id") else { return nil }
      return OnboardingAppIcon(id: id, name: icon.string("name") ?? id, preview: SettingsAdapters.image(icon.string("preview")))
    }
  }

  func currentAppIcon() async -> String? { await Self.call("onboarding.currentAppIcon") as? String }

  func setAppIcon(_ id: String) async { await Self.call("appearance.setAppIcon", id) }

  func pinnedHosts(_ windowId: String) -> Set<String> {
    guard windowId == self.windowId else { return [] }
    return Set(window.strings("pinnedHosts"))
  }

  func history(_ windowId: String) -> [OnboardingHistoryVisit] {
    guard windowId == self.windowId else { return [] }
    return window.list("history").compactMap { entry in
      guard let url = entry.string("url") else { return nil }
      return OnboardingHistoryVisit(url: url, visits: entry.int("visits") ?? 0)
    }
  }

  func openPinnedTabs(_ windowId: String, _ sites: [PinnableSite]) {
    Self.fire("onboarding.pinSites", windowId, sites.map(\.id))
  }

  func favicon(_ url: String) async -> NSImage? {
    guard let uri = await Self.call("favicon.uri", url, window.string("profileId") ?? NSNull()) as? String else { return nil }
    return SettingsAdapters.image(uri)
  }

  static let connectWait = Duration.seconds(5)

  static func fire(_ name: String, _ args: Any...) {
    Task { _ = await invoke(name, args) }
  }

  @discardableResult
  static func call(_ name: String, _ args: Any...) async -> Any? {
    await invoke(name, args)
  }

  private static func invoke(_ name: String, _ args: [Any]) async -> Any? {
    let deadline = ContinuousClock.now + connectWait
    while !SettingsJS.shared.connected, ContinuousClock.now < deadline {
      try? await Task.sleep(for: .milliseconds(100))
    }
    do {
      return try await SettingsJS.shared.invoke(name, args)
    } catch {
      NSLog("[onboarding] %@ failed: %@", name, String(describing: error))
      return nil
    }
  }
}
