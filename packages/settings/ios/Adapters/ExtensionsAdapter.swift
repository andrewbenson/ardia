import AppKit
import Foundation
import Observation
import SolaraUI

@MainActor
@Observable
final class ExtensionsAdapter: ExtensionsServices {
  private(set) var focusedWindowProfileId: String?
  @ObservationIgnored private var observer: UUID?

  init() {
    focusedWindowProfileId = SettingsJS.shared.latestValue("extensions.defaultProfile") as? String
    observer = SettingsJS.shared.observe("extensions.defaultProfile") { [weak self] value in
      self?.focusedWindowProfileId = value as? String
    }
  }

  isolated deinit {
    if let observer { SettingsJS.shared.stopObserving("extensions.defaultProfile", observer) }
  }

  func listExtensions(profile: String) async throws -> [InstalledExtension] {
    let list = try await Self.call("extensions.list", profile) as? [[String: Any]] ?? []
    return list.compactMap(Self.installed)
  }

  func setExtensionEnabled(_ id: String, enabled: Bool, profile: String) async throws {
    try await Self.call("extensions.setEnabled", id, enabled, profile)
  }

  func uninstallExtension(_ id: String, profile: String) async throws {
    try await Self.call("extensions.uninstall", id, profile)
  }

  func reloadExtension(_ id: String, profile: String) async throws {
    try await Self.call("extensions.reload", id, profile)
  }

  func configureExtension(_ id: String, profile: String, options: ExtensionConfiguration) async throws {
    var patch: [String: Any] = [:]
    if let pinned = options.pinned { patch["pinned"] = pinned }
    if let incognito = options.incognito { patch["incognito"] = incognito }
    if let siteAccess = options.siteAccess { patch["siteAccess"] = siteAccess.rawValue }
    try await Self.call("extensions.configure", id, profile, patch)
  }

  func chooseExtensionFolder() async -> String? {
    let panel = NSOpenPanel()
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.allowsMultipleSelection = false
    panel.prompt = "Select"
    panel.message = "Choose an extension folder (with a manifest.json)"
    let response = await panel.begin()
    return response == .OK ? panel.url?.path : nil
  }

  func inspectUnpackedExtension(path: String) async throws -> ExtensionPackage {
    guard let dict = try await Self.call("extensions.inspectUnpacked", path) as? [String: Any] else {
      throw ExtensionServiceError("That folder couldn't be read as an extension.")
    }
    return ExtensionPackage(
      name: dict.string("name") ?? "Extension",
      version: dict.string("version") ?? "",
      icon: dict.string("icon"),
      permissions: dict.strings("permissions"),
      hostPermissions: dict.strings("hostPermissions"),
      path: dict.string("path") ?? path
    )
  }

  func installExtension(path: String, profile: String) async throws {
    try await Self.call("extensions.install", path, profile)
  }

  func extensionChanges() -> AsyncStream<ExtensionsChange> {
    SettingsJS.shared.stream("extensions.changed") { value -> ExtensionsChange? in
      guard let dict = value as? [String: Any], let profile = dict.string("profile"), let id = dict.string("id"),
            let event = dict.string("event").flatMap(ExtensionsChange.Event.init(rawValue:)) else { return nil }
      return ExtensionsChange(profile: profile, id: id, event: event)
    }
  }

  func closeExtensionSurfaces(_ id: String) { SettingsJS.shared.fire("extensions.closeSurfaces", id) }

  func openWebStoreDetail(_ url: String, profile: String) { SettingsJS.shared.fire("extensions.openWebStoreDetail", url, profile) }

  func openInNewTab(_ url: String) { SettingsJS.shared.fire("extensions.openInNewTab", url) }

  @discardableResult
  private static func call(_ name: String, _ args: Any...) async throws -> Any? {
    do {
      return try await SettingsJS.shared.invoke(name, args)
    } catch let error as SettingsJSError {
      throw ExtensionServiceError(error.description)
    }
  }

  static func installed(_ dict: [String: Any]) -> InstalledExtension? {
    guard let id = dict.string("id") else { return nil }
    let enabled = dict.bool("enabled") ?? false
    return InstalledExtension(
      id: id,
      name: dict.string("name") ?? id,
      version: dict.string("version") ?? "",
      description: dict.string("description") ?? "",
      enabled: enabled,
      state: dict.string("state"),
      icon: dict.string("icon") ?? "",
      permissions: dict.strings("permissions"),
      siteAccess: dict.string("siteAccess").map(ExtensionSiteAccess.init(engineValue:)),
      optionsUrl: dict.string("optionsUrl"),
      pinned: dict.bool("pinned") ?? false,
      incognito: dict.bool("incognito") ?? false,
      mayModify: dict.bool("mayModify") ?? true,
      errors: dict.strings("errors"),
      path: dict.string("path"),
      fromWebStore: dict.bool("fromWebStore") ?? false,
      webStoreUrl: dict.string("webStoreUrl")
    )
  }
}
