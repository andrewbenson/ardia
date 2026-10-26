import Foundation
import Observation
import SolaraUI

@MainActor
final class PrivacyAdapter: PrivacyServices {
  func contentBlocker() async -> ContentBlockerState? {
    (await SettingsAdapters.js("privacy.contentBlocker") as? [String: Any]).map(Self.blocker)
  }

  func contentBlockerChanges() -> AsyncStream<Void> {
    SettingsJS.shared.stream("privacy.contentBlockerChanged") { _ in () }
  }

  func setContentBlockerEnabled(_ on: Bool) async throws {
    _ = try await SettingsAdapters.jsThrowing("privacy.setContentBlockerEnabled", on)
  }

  func setFilterListEnabled(_ id: String, enabled: Bool) async throws {
    _ = try await SettingsAdapters.jsThrowing("privacy.setFilterListEnabled", id, enabled)
  }

  func setContentBlockerAllowed(host: String, allowed: Bool) async throws {
    _ = try await SettingsAdapters.jsThrowing("privacy.setContentBlockerAllowed", host, allowed)
  }

  func siteSettingsOrigins(profile: String) async -> [String] {
    await SettingsAdapters.js("privacy.siteSettingsOrigins", profile) as? [String] ?? []
  }

  func siteSettings(profile: String, origin: String) async -> [SiteSettingType: SiteSettingState]? {
    guard let raw = await SettingsAdapters.js("privacy.siteSettings", profile, origin) as? [String: Any] else { return nil }
    var settings: [SiteSettingType: SiteSettingState] = [:]
    for (key, entry) in raw {
      guard let type = SiteSettingType(rawValue: key), let entry = entry as? [String: Any],
            let value = entry.string("value").flatMap(SiteSettingValue.init(rawValue:)) else { continue }
      settings[type] = SiteSettingState(value: value, isDefault: entry.bool("isDefault") ?? false)
    }
    return settings
  }

  func setSiteSetting(profile: String, origin: String, type: SiteSettingType, value: SiteSettingValue) async {
    await SettingsAdapters.js("privacy.setSiteSetting", profile, origin, type.rawValue, value.rawValue)
  }

  func resetSiteSettings(profile: String, origin: String) async {
    await SettingsAdapters.js("privacy.resetSiteSettings", profile, origin)
  }

  func clearSiteData(profile: String, origin: String) async -> ClearSiteDataResult {
    let result = await SettingsAdapters.js("privacy.clearSiteData", profile, origin) as? [String: Any] ?? [:]
    let cookies = (result["cookies"] as? NSNumber).flatMap { CFGetTypeID($0) == CFBooleanGetTypeID() ? nil : $0.intValue }
    return ClearSiteDataResult(cookies: cookies, storage: result.bool("storage") ?? false)
  }

  func externalAppAllowances(profile: String) async -> [ExternalAppAllowance] {
    let list = await SettingsAdapters.js("privacy.externalAppAllowances", profile) as? [[String: Any]] ?? []
    return list.compactMap { entry in
      guard let origin = entry.string("origin"), let scheme = entry.string("scheme") else { return nil }
      return ExternalAppAllowance(origin: origin, scheme: scheme, app: entry.string("app"), icon: entry.string("icon"))
    }
  }

  func removeExternalAppAllowance(profile: String, origin: String, scheme: String) async {
    await SettingsAdapters.js("privacy.removeExternalAppAllowance", profile, origin, scheme)
  }

  func zoomLevels(profile: String) async -> [String: Double] {
    let levels = await SettingsAdapters.js("privacy.zoomLevels", profile) as? [String: Any] ?? [:]
    return levels.compactMapValues { ($0 as? NSNumber)?.doubleValue }
  }

  func setZoom(profile: String, host: String, zoom: Double) async {
    await SettingsAdapters.js("privacy.setZoom", profile, host, zoom)
  }

  static func blocker(_ dict: [String: Any]) -> ContentBlockerState {
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

@MainActor
@Observable
final class DiagnosticsSharingAdapter: DiagnosticsSharingServices {
  private var latest: [String: Any]
  @ObservationIgnored private var observer: UUID?

  init() {
    latest = SettingsJS.shared.latestValue("privacy.diagnostics") as? [String: Any] ?? [:]
    observer = SettingsJS.shared.observe("privacy.diagnostics") { [weak self] value in
      self?.latest = value as? [String: Any] ?? [:]
    }
  }

  var available: Bool { latest.bool("available") ?? false }
  var sharing: Bool { latest.bool("sharing") ?? false }

  func setSharing(_ on: Bool, source: String) {
    guard !on || available else { return }
    latest["sharing"] = on
    SettingsJS.shared.fire("privacy.setSharing", on, source)
  }

  var telemetryHost: String { latest.string("telemetryHost") ?? "" }
  var updateHost: String { latest.string("updateHost") ?? "" }
  var switchFile: String { latest.string("switchFile") ?? "" }
}
