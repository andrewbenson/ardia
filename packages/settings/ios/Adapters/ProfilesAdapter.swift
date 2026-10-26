import AppKit
import Foundation
import Observation
import SolaraModel
import SolaraUI
import SwiftUI

@MainActor
@Observable
final class ProfilesAdapter: ProfilesServices {
  private(set) var profiles: [ProfileSummary]
  private(set) var appDark: Bool
  private var statsByProfile: [String: ProfileStats]
  @ObservationIgnored private let store: SettingsStoreSource
  @ObservationIgnored private var observers: [(String, UUID)] = []

  init(store: SettingsStoreSource) {
    self.store = store
    let js = SettingsJS.shared
    profiles = Self.profiles(js.latestValue("profiles.list"))
    appDark = js.latestValue("profiles.appDark") as? Bool ?? true
    statsByProfile = Self.stats(js.latestValue("profiles.stats"))
    observers.append(("profiles.list", js.observe("profiles.list") { [weak self] in self?.profiles = Self.profiles($0) }))
    observers.append(("profiles.appDark", js.observe("profiles.appDark") { [weak self] in self?.appDark = $0 as? Bool ?? true }))
    observers.append(("profiles.stats", js.observe("profiles.stats") { [weak self] in self?.statsByProfile = Self.stats($0) }))
  }

  func stats(profileId: String) -> ProfileStats {
    statsByProfile[profileId] ?? ProfileStats(historyPages: 0, bookmarks: 0)
  }

  func createProfile(name: String, color: ProfileColorValue, shareWith: String?) -> String {
    SettingsJS.shared.fire("profiles.create", name, color.rawValue, jsonArg(shareWith))
    return ""
  }

  func updateProfile(_ id: String, _ patch: ProfilePatch) {
    var arg: [String: Any] = [:]
    if let name = patch.name { arg["name"] = name }
    if let color = patch.color { arg["color"] = color.rawValue }
    if let icon = patch.icon { arg["icon"] = jsonArg(icon) }
    if let theme = patch.theme { arg["theme"] = theme.flatMap(Self.json) ?? NSNull() }
    guard !arg.isEmpty else { return }
    if let index = profiles.firstIndex(where: { $0.id == id }) {
      var profile = profiles[index]
      if let name = patch.name { profile.name = name }
      if let color = patch.color { profile.color = color }
      if let icon = patch.icon { profile.icon = icon }
      if let theme = patch.theme { profile.theme = theme }
      profiles[index] = profile
    }
    SettingsJS.shared.fire("profiles.update", id, arg)
  }

  func deleteProfile(_ id: String) {
    guard profiles.count > 1, profiles.contains(where: { $0.id == id }) else { return }
    profiles.removeAll { $0.id == id }
    Task {
      await SettingsAdapters.js("profiles.delete", id)
      resync()
    }
  }

  func reorderProfiles(_ ids: [String]) {
    let known = ids.compactMap { id in profiles.first { $0.id == id } }
    profiles = known + profiles.filter { !ids.contains($0.id) }
    Task {
      await SettingsAdapters.js("profiles.reorder", ids)
      resync()
    }
  }

  func setDefaultProfile(_ id: String) { store.set("defaultProfileId", id) }

  func clearHistory(profileId: String, since: Date?) {
    SettingsJS.shared.fire("profiles.clearHistory", profileId, Self.millis(since))
  }

  func pruneProfileFavicons(profileId: String) {
    SettingsJS.shared.fire("profiles.pruneFavicons", profileId)
  }

  func clearBrowsingData(engineProfile: String, kinds: [BrowsingDataKind], since: Date?) async {
    await SettingsAdapters.js("profiles.clearBrowsingData", engineProfile, kinds.map(\.rawValue), Self.millis(since))
  }

  func extensionsKeptOnDelete() async -> [String]? {
    await SettingsAdapters.js("profiles.extensionsKeptOnDelete") as? [String]
  }

  func adoptProfileTheme(_ id: String) { SettingsJS.shared.fire("profiles.adoptTheme", id) }

  func holdThemedWindowsKeyLook(_ on: Bool) { SettingsJS.shared.fire("profiles.holdKeyLook", on) }

  func arcThemeChoices() async -> [ArcThemeChoice] {
    let list = await SettingsAdapters.js("profiles.arcThemeChoices") as? [[String: Any]] ?? []
    return list.compactMap { choice in
      guard let id = choice.string("id"), let theme = Self.theme(choice["theme"]) else { return nil }
      return ArcThemeChoice(id: id, name: choice.string("name") ?? "", emoji: choice.string("emoji"), theme: theme)
    }
  }

  func themeSwatch(_ spec: ThemeSwatchSpec) -> AnyView? { nil }

  func hapticTick() {
    NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
  }

  private func resync() {
    profiles = Self.profiles(SettingsJS.shared.latestValue("profiles.list"))
  }

  static func millis(_ date: Date?) -> Any {
    date.map { ($0.timeIntervalSince1970 * 1000).rounded() } ?? NSNull()
  }

  static func profiles(_ value: Any?) -> [ProfileSummary] {
    ((value as? [String: Any])?.list("profiles") ?? []).compactMap { profile in
      guard let id = profile.string("id") else { return nil }
      return ProfileSummary(
        id: id,
        name: profile.string("name") ?? "",
        color: profile.string("color").flatMap(ProfileColorValue.init(rawValue:)) ?? .plum,
        icon: profile.string("icon"),
        dataId: profile.string("dataId"),
        theme: theme(profile["theme"])
      )
    }
  }

  static func stats(_ value: Any?) -> [String: ProfileStats] {
    guard let dict = value as? [String: Any] else { return [:] }
    var result: [String: ProfileStats] = [:]
    for (id, entry) in dict {
      guard let entry = entry as? [String: Any] else { continue }
      result[id] = ProfileStats(historyPages: entry.int("historyPages") ?? 0, bookmarks: entry.int("bookmarks") ?? 0)
    }
    return result
  }

  static func theme(_ value: Any?) -> ProfileThemeValue? {
    guard let value, !(value is NSNull), JSONSerialization.isValidJSONObject(value),
          let data = try? JSONSerialization.data(withJSONObject: value) else { return nil }
    return try? JSONDecoder().decode(ProfileThemeValue.self, from: data)
  }

  static func json(_ theme: ProfileThemeValue) -> Any? {
    guard let data = try? JSONEncoder().encode(theme) else { return nil }
    return try? JSONSerialization.jsonObject(with: data)
  }
}
