import AppKit
import ArdiaShell
import Foundation
import Observation
import SolaraModel
import SolaraOmnibox
import SolaraUI

@MainActor
final class GeneralAdapter: GeneralServices {
  func loginItemStatus() async -> LoginItemStatus {
    (await SettingsAdapters.js("general.loginItemStatus") as? String).flatMap(LoginItemStatus.init(rawValue:)) ?? .notRegistered
  }

  func setLaunchAtLogin(_ on: Bool) async { await SettingsAdapters.js("general.setLaunchAtLogin", on) }

  func isDefaultBrowser() async -> Bool { await SettingsAdapters.js("general.isDefaultBrowser") as? Bool ?? false }

  func setAsDefaultBrowser() async -> Bool { await SettingsAdapters.js("general.setAsDefaultBrowser") as? Bool ?? false }

  func downloadSettings(profile: String) async -> DownloadSettings? {
    (await SettingsAdapters.js("general.downloadSettings", profile) as? [String: Any]).flatMap(Self.downloads)
  }

  func setDownloadSettings(folder: String?, askWhereToSave: Bool?, profile: String) async -> DownloadSettings? {
    var patch: [String: Any] = [:]
    if let folder { patch["folder"] = folder }
    if let askWhereToSave { patch["askWhereToSave"] = askWhereToSave }
    return (await SettingsAdapters.js("general.setDownloadSettings", patch, profile) as? [String: Any]).flatMap(Self.downloads)
  }

  func pickFolder(current: String, prompt: String) async -> String? {
    let panel = NSOpenPanel()
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.canCreateDirectories = true
    panel.allowsMultipleSelection = false
    panel.prompt = prompt
    panel.directoryURL = URL(fileURLWithPath: current, isDirectory: true)
    let response = await panel.begin()
    return response == .OK ? panel.url?.path : nil
  }

  func openImport() { SettingsJS.shared.fire("general.openImport") }

  static func downloads(_ dict: [String: Any]) -> DownloadSettings? {
    guard let folder = dict.string("folder") else { return nil }
    return DownloadSettings(folder: folder, askWhereToSave: dict.bool("askWhereToSave") ?? false, managed: dict.bool("managed") ?? false)
  }
}

@MainActor
final class AppearanceAdapter: AppearanceServices {
  func appIcons(size: CGFloat) async -> (icons: [AppIconChoice], current: String?) {
    let result = await SettingsAdapters.js("appearance.appIcons", Double(size)) as? [String: Any] ?? [:]
    let icons = result.list("icons").compactMap { icon -> AppIconChoice? in
      guard let id = icon.string("id") else { return nil }
      return AppIconChoice(id: id, name: icon.string("name") ?? id, preview: SettingsAdapters.image(icon.string("preview")))
    }
    return (icons, result.string("current"))
  }

  func setAppIcon(_ id: String) async { await SettingsAdapters.js("appearance.setAppIcon", id) }

  func setAppearance(_ mode: String) async {
    NSApp.appearance = mode == "light" ? NSAppearance(named: .aqua) : mode == "dark" ? NSAppearance(named: .darkAqua) : nil
  }
}

@MainActor
@Observable
final class SearchEngineAdapter: SearchEngineServices {
  private var latest: [String: Any]
  @ObservationIgnored private var observer: UUID?

  init() {
    latest = SettingsJS.shared.latestValue("search.engines") as? [String: Any] ?? [:]
    observer = SettingsJS.shared.observe("search.engines") { [weak self] value in
      self?.latest = value as? [String: Any] ?? [:]
    }
  }

  func engineList() -> SearchEngineList {
    let engines = latest.list("engines").compactMap { engine -> SearchEngineItem? in
      guard let id = engine.string("id") else { return nil }
      let extensionName = engine.dict("extension").map { $0.string("name") ?? "" }
      return SearchEngineItem(
        id: id,
        name: engine.string("name") ?? id,
        keyword: engine.string("keyword") ?? "",
        url: engine.string("url") ?? "",
        host: engine.string("host") ?? "",
        custom: engine.bool("custom") ?? false,
        extensionName: extensionName
      )
    }
    let controlling = latest.dict("controlling").flatMap { c -> ControllingSearchExtension? in
      guard let id = c.string("extensionId"), let profile = c.string("profile") else { return nil }
      return ControllingSearchExtension(extensionId: id, extensionName: c.string("extensionName") ?? "", profile: profile)
    }
    return SearchEngineList(engines: engines, selectedId: latest.string("selectedId") ?? "", controlling: controlling)
  }

  func setSearchEngine(_ id: String) { SettingsJS.shared.fire("search.setEngine", id) }

  func addCustomEngine(_ input: SearchEngineInput) async -> String? {
    await SettingsAdapters.js("search.add", Self.arg(input)) as? String
  }

  func updateCustomEngine(_ id: String, _ input: SearchEngineInput) async -> String? {
    await SettingsAdapters.js("search.update", id, Self.arg(input)) as? String
  }

  func removeCustomEngine(_ id: String) { SettingsJS.shared.fire("search.remove", id) }

  func manageExtensions(profile: String) { SettingsJS.shared.fire("search.manageExtensions", profile) }

  func disableExtension(profile: String, extensionId: String) async {
    await SettingsAdapters.js("search.disableExtension", profile, extensionId)
  }

  static func arg(_ input: SearchEngineInput) -> [String: Any] {
    ["name": input.name, "keyword": input.keyword, "url": input.url]
  }
}

@MainActor
final class EnginesAdapter: EnginesServices {
  func setWebsiteEngine(_ site: String, _ engine: String?) {
    SettingsJS.shared.fire("engines.setWebsiteEngine", site, jsonArg(engine))
  }

  func site(forTyped address: String) -> String? {
    let typed = address.trimmingCharacters(in: .whitespacesAndNewlines)
    let url = typed.range(of: "^[a-z][\\w+.-]*://", options: [.regularExpression, .caseInsensitive]) != nil ? typed : SolaraOmnibox.resolveInput(typed, search: "")
    guard let components = URLComponents(string: url), let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https",
          let host = components.host, !host.isEmpty else { return nil }
    let port = components.port.map { ":\($0)" } ?? ""
    return "\(scheme)://\(host)\(port)".lowercased()
  }

  func passkeyAccess() async -> PasskeyAccess? {
    Self.passkeys(await SettingsAdapters.js("engines.passkeyAccess") as? [String: Any])
  }

  func requestPasskeyAccess() async -> PasskeyAccess? {
    Self.passkeys(await SettingsAdapters.js("engines.requestPasskeyAccess") as? [String: Any])
  }

  func openPasskeySystemSettings() {
    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security") { NSWorkspace.shared.open(url) }
  }

  static func passkeys(_ dict: [String: Any]?) -> PasskeyAccess? {
    guard let dict, let status = dict.string("status").flatMap(PasskeyAccessStatus.init(rawValue:)) else { return nil }
    return PasskeyAccess(entitled: dict.bool("entitled") ?? false, status: status)
  }
}

@MainActor
@Observable
final class AdvancedAdapter: AdvancedServices {
  private var cli: [String: Any]
  private var developerModeChanged: Bool
  @ObservationIgnored private var observers: [UUID] = []

  init() {
    cli = SettingsJS.shared.latestValue("advanced.cli") as? [String: Any] ?? [:]
    developerModeChanged = SettingsJS.shared.latestValue("advanced.developerModeChanged") as? Bool ?? false
    observers.append(SettingsJS.shared.observe("advanced.cli") { [weak self] in self?.cli = $0 as? [String: Any] ?? [:] })
    observers.append(SettingsJS.shared.observe("advanced.developerModeChanged") { [weak self] in self?.developerModeChanged = $0 as? Bool ?? false })
  }

  func chromiumVersion() async -> String? {
    if let version = AboutInfo.read().chromiumVersion { return version }
    return await SettingsAdapters.js("advanced.chromiumVersion") as? String
  }

  func widevineVersion() async -> String?? {
    .some(await SettingsAdapters.js("advanced.widevineVersion") as? String)
  }

  var cliServer: CliServerStatus? {
    cli.dict("server").map { CliServerStatus(state: $0.string("state") ?? "off", reason: $0.string("reason"), connections: $0.int("connections")) }
  }

  var cliInstall: CliInstallState {
    CliInstallState(
      installing: cli.bool("installing") ?? false,
      step: cli.string("step"),
      installedVersion: cli.string("installedVersion"),
      binPath: cli.string("binPath"),
      error: cli.string("error")
    )
  }

  func installCli() { SettingsJS.shared.fire("advanced.installCli") }

  func hasDeveloperModeChanges(_ developerMode: JSONValue?) -> Bool {
    _ = developerMode
    return developerModeChanged
  }

  func resetDeveloperModeSites() { SettingsJS.shared.fire("advanced.resetDeveloperModeSites") }

  func openInternalPage(_ page: String) { SettingsJS.shared.fire("app.openInternalPage", page) }

  func openURL(_ url: String) { SettingsJS.shared.fire("app.openUrls", [url]) }

  var systemInfo: AdvancedSystemInfo {
    let info = AboutInfo.read(releaseRepo: Self.releaseRepo)
    return AdvancedSystemInfo(releaseRepo: info.releaseRepo, appVersion: info.appVersion)
  }

  static var releaseRepo: String? {
    let repo = (Bundle.main.object(forInfoDictionaryKey: "ACReleaseRepo") as? String ?? "").trimmingCharacters(in: .whitespaces)
    return repo.isEmpty || repo.hasPrefix("$(") ? nil : repo
  }
}

@MainActor
final class AboutAdapter: AboutServices {
  let aboutInfo = AboutInfo.read(releaseRepo: AdvancedAdapter.releaseRepo)

  func updaterState() async -> UpdaterState? {
    let state = AppUpdater.shared.state
    guard state["available"] as? Bool == true else { return nil }
    return UpdaterState(
      configured: state.bool("configured") ?? false,
      automaticChecks: state.bool("automaticChecks") ?? false,
      automaticDownloads: state.bool("automaticDownloads") ?? false,
      canCheck: state.bool("canCheck") ?? false,
      sessionInProgress: state.bool("sessionInProgress") ?? false,
      lastCheck: state.date("lastCheck"),
      version: state.string("version") ?? aboutInfo.appVersion,
      displayVersion: state.string("displayVersion"),
      channel: state.string("channel")
    )
  }

  func setAutomaticUpdateChecks(_ on: Bool) async { AppUpdater.shared.setAutomaticChecks(on) }
  func setAutomaticUpdateDownloads(_ on: Bool) async { AppUpdater.shared.setAutomaticDownloads(on) }
  func setUpdateChannel(_ channel: String) async { AppUpdater.shared.setChannel(channel) }
  func checkForUpdates() async { AppUpdater.shared.checkForUpdates(nil) }

  var updateChecksNote: String? { SettingsJS.shared.latestValue("about.updateChecksNote") as? String }

  func copyText(_ text: String) { SettingsAdapters.copyText(text) }

  func openURL(_ url: String) { SettingsJS.shared.fire("app.openUrls", [url]) }
}
