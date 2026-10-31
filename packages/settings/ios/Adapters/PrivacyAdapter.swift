import SolaraCore
import Foundation
import Observation
import SolaraUI

@MainActor
final class PrivacyAdapter: PrivacyServices {
  func contentBlocker() async -> ContentBlockerState? {
    await EngineCalls.result({ done in SolaraCoreContentBlocker.state { done($0) } }) { EngineCalls.failed($0, "contentBlocker") ? nil : Self.blocker($0) }
  }

  func contentBlockerChanges() -> AsyncStream<Void> {
    AsyncStream { continuation in
      let observer = NotificationCenter.default.addObserver(forName: SolaraCoreSettingsBridge.contentBlockerChanged, object: nil, queue: .main) { _ in
        continuation.yield()
      }
      nonisolated(unsafe) let token = observer
      continuation.onTermination = { _ in NotificationCenter.default.removeObserver(token) }
    }
  }

  func setContentBlockerEnabled(_ on: Bool) async throws {
    try await EngineCalls.settle { done in SolaraCoreContentBlocker.setEnabled(on) { done($0) } }
  }

  func setFilterListEnabled(_ id: String, enabled: Bool) async throws {
    try await EngineCalls.settle { done in SolaraCoreContentBlocker.setList(id, enabled: enabled) { done($0) } }
  }

  func setContentBlockerAllowed(host: String, allowed: Bool) async throws {
    try await EngineCalls.settle { done in SolaraCoreContentBlocker.setAllowed(allowed, host: host) { done($0) } }
  }

  func siteSettingsOrigins(profile: String) async -> [String] {
    await withCheckedContinuation { continuation in
      SolaraCoreServices.siteSettingsOrigins(profile: profile) { continuation.resume(returning: $0) }
    }
  }

  func siteSettings(profile: String, origin: String) async -> [SiteSettingType: SiteSettingState]? {
    await EngineCalls.result({ done in SolaraCoreServices.siteSettings(profile: profile, origin: origin) { done($0) } }) {
      EngineCalls.failed($0, "siteSettings") ? nil : Self.siteSettings($0)
    }
  }

  nonisolated static func siteSettings(_ raw: [String: Any]) -> [SiteSettingType: SiteSettingState] {
    var settings: [SiteSettingType: SiteSettingState] = [:]
    for (key, entry) in raw {
      guard let type = SiteSettingType(rawValue: key), let entry = entry as? [String: Any],
            let value = entry.string("value").flatMap(SiteSettingValue.init(rawValue:)) else { continue }
      settings[type] = SiteSettingState(value: value, isDefault: entry.bool("isDefault") ?? false)
    }
    return settings
  }

  func setSiteSetting(profile: String, origin: String, type: SiteSettingType, value: SiteSettingValue) async {
    SolaraCoreServices.setSiteSetting(value.rawValue, profile: profile, origin: origin, type: type.rawValue)
  }

  func resetSiteSettings(profile: String, origin: String) async {
    SolaraCoreServices.resetSiteSettings(profile: profile, origin: origin)
  }

  func clearSiteData(profile: String, origin: String) async -> ClearSiteDataResult {
    await EngineCalls.result({ done in SolaraCoreServices.clearSiteData(profile: profile, origin: origin) { done($0) } }) { result in
      let cookies = (result["cookies"] as? NSNumber).flatMap { CFGetTypeID($0) == CFBooleanGetTypeID() ? nil : $0.intValue }
      return ClearSiteDataResult(cookies: cookies, storage: result.bool("storage") ?? false)
    }
  }

  func externalAppAllowances(profile: String) async -> [ExternalAppAllowance] {
    let chromium: [ExternalAppAllowance] = await withCheckedContinuation { continuation in
      SolaraCoreServices.externalAppAllowances(profile: profile) { list in
        continuation.resume(returning: Self.allowances(list as? [[String: Any]] ?? []))
      }
    }
    let seen = Set(chromium.map { "\($0.origin)|\($0.scheme)" })
    let webkit = Self.allowances(SolaraCoreSettingsBridge.webKitExternalAppAllowances(profile: profile))
    return chromium + webkit.filter { !seen.contains("\($0.origin)|\($0.scheme)") }
  }

  nonisolated static func allowances(_ list: [[String: Any]]) -> [ExternalAppAllowance] {
    list.compactMap { entry in
      guard let origin = entry.string("origin"), let scheme = entry.string("scheme") else { return nil }
      return ExternalAppAllowance(origin: origin, scheme: scheme, app: entry.string("app"), icon: entry.string("icon"))
    }
  }

  func removeExternalAppAllowance(profile: String, origin: String, scheme: String) async {
    SolaraCoreServices.removeExternalAppAllowance(profile: profile, origin: origin, scheme: scheme)
    SolaraCoreSettingsBridge.removeWebKitExternalAppAllowance(profile: profile, origin: origin, scheme: scheme)
  }

  func zoomLevels(profile: String) async -> [String: Double] {
    await withCheckedContinuation { continuation in
      SolaraCoreServices.zoomLevels(profile: profile) { levels in continuation.resume(returning: levels.mapValues(\.doubleValue)) }
    }
  }

  func setZoom(profile: String, host: String, zoom: Double) async {
    SolaraCoreServices.setZoom(zoom, profile: profile, host: host)
  }

  nonisolated static func blocker(_ dict: [String: Any]) -> ContentBlockerState {
    let lists = dict.list("lists").compactMap { list -> FilterList? in
      guard let id = list.string("id"), let category = list.string("category").flatMap(FilterListCategory.init(rawValue:)) else { return nil }
      return FilterList(
        id: id,
        title: list.string("title") ?? id,
        category: category,
        enabled: list.bool("enabled") ?? false,
        defaultOn: list.bool("defaultOn") ?? false,
        filters: list.int("filters") ?? 0
      )
    }
    let stats = dict.dict("stats") ?? [:]
    return ContentBlockerState(
      enabled: dict.bool("enabled") ?? false,
      version: dict.string("version") ?? "",
      lists: lists,
      allowedHosts: dict.strings("allowedHosts"),
      networkFilters: stats.int("networkFilters"),
      cosmeticFilters: stats.int("cosmeticFilters")
    )
  }
}

