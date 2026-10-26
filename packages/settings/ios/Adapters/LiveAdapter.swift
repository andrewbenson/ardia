import AppKit
import Foundation
import SolaraUI

@MainActor
final class LiveAdapter: LiveFoldersServices, CalendarServices {
  static let foldersTopic = "liveFolders.state"
  static let calendarTopic = "calendar.state"

  func liveFoldersState() async -> LiveFoldersState {
    Self.foldersState(SettingsJS.shared.latestValue(Self.foldersTopic))
  }

  func liveFoldersChanges() -> AsyncStream<LiveFoldersState> {
    SettingsJS.shared.stream(Self.foldersTopic) { Self.foldersState($0) }
  }

  func refreshFolder(_ id: String) async { await SettingsAdapters.js("liveFolders.refreshFolder", id) }

  func deleteFolder(_ id: String) { SettingsJS.shared.fire("liveFolders.deleteFolder", id) }

  func updateFolder(_ id: String, groupStacks: Bool?, showCompleted: Bool?) {
    var patch: [String: Any] = [:]
    if let groupStacks { patch["groupStacks"] = groupStacks }
    if let showCompleted { patch["showCompleted"] = showCompleted }
    guard !patch.isEmpty else { return }
    SettingsJS.shared.fire("liveFolders.updateFolder", id, patch)
  }

  func disconnect(_ source: LiveSourceId) async { await SettingsAdapters.js("liveFolders.disconnect", source.rawValue) }

  func connectGithub(token: String) async throws { try await Self.connect("liveFolders.connectGithub", token) }

  func setGithubClientId(_ clientId: String) { SettingsJS.shared.fire("liveFolders.setGithubClientId", clientId) }

  func startGithubDeviceFlow(clientId: String) async throws -> LiveDeviceFlow {
    let result = try await Self.connect("liveFolders.startGithubDeviceFlow", clientId) as? [String: Any]
    guard let result, let id = result.string("id"), let userCode = result.string("userCode"), let uri = result.string("verificationUri") else {
      throw LiveConnectError("GitHub didn't start the sign-in")
    }
    return LiveDeviceFlow(id: id, userCode: userCode, verificationUri: uri)
  }

  func finishGithubDeviceFlow(_ flow: LiveDeviceFlow) async throws { try await Self.connect("liveFolders.finishGithubDeviceFlow", flow.id) }

  func cancelGithubDeviceFlow(_ flow: LiveDeviceFlow) { SettingsJS.shared.fire("liveFolders.cancelGithubDeviceFlow", flow.id) }

  func connectBitbucket(user: String, token: String) async throws { try await Self.connect("liveFolders.connectBitbucket", user, token) }

  func connectNotion(token: String) async throws { try await Self.connect("liveFolders.connectNotion", token) }

  func connectConfluence(site: String, email: String, token: String) async throws {
    try await Self.connect("liveFolders.connectConfluence", site, email, token)
  }

  func connectGoogleDrive(clientId: String, clientSecret: String) async throws {
    try await Self.connect("liveFolders.connectGoogleDrive", clientId, clientSecret)
  }

  func copyText(_ text: String) { SettingsAdapters.copyText(text) }

  func openInBrowser(_ url: String) { SettingsJS.shared.fire("liveFolders.openInBrowser", url) }

  func favicon(site: String) async -> NSImage? { await SettingsAdapters.favicon(url: site, profile: nil) }

  func calendarState() async -> CalendarPaneState {
    Self.calendarState(SettingsJS.shared.latestValue(Self.calendarTopic))
  }

  func calendarChanges() -> AsyncStream<CalendarPaneState> {
    SettingsJS.shared.stream(Self.calendarTopic) { Self.calendarState($0) }
  }

  func refreshCalendar() async { await SettingsAdapters.js("calendar.refresh") }

  func connectCalendar() async { await SettingsAdapters.js("calendar.connect") }

  func updateCalendarOptions(_ change: LiveCalendarOptionChange) {
    let patch: [String: Any] = switch change {
    case .alertLead(let value): ["alertLead": value]
    case .alertCondition(let value): ["alertCondition": value]
    case .showPreview(let value): ["showPreview": value]
    case .showTimeToNext(let value): ["showTimeToNext": value]
    }
    SettingsJS.shared.fire("calendar.updateOptions", patch)
  }

  func setCalendarHidden(_ id: String, hidden: Bool) { SettingsJS.shared.fire("calendar.setHidden", id, hidden) }

  func openCalendarPrivacySettings() {
    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") { NSWorkspace.shared.open(url) }
  }

  @discardableResult
  static func connect(_ name: String, _ args: Any...) async throws -> Any? {
    do {
      return try await SettingsJS.shared.invoke(name, args)
    } catch let error as SettingsJSError {
      throw LiveConnectError(error.description)
    }
  }

  static func foldersState(_ value: Any?) -> LiveFoldersState {
    let dict = value as? [String: Any] ?? [:]
    let folders = dict.list("folders").compactMap(folder)
    var accounts: [LiveSourceId: LiveAccount] = [:]
    for (key, raw) in dict.dict("accounts") ?? [:] {
      guard let source = LiveSourceId(rawValue: key), let account = raw as? [String: Any], let login = account.string("login") else { continue }
      accounts[source] = LiveAccount(login: login, name: account.string("name"))
    }
    let config = dict.dict("config") ?? [:]
    return LiveFoldersState(
      folders: folders,
      accounts: accounts,
      config: LiveConfig(
        githubClientId: config.string("githubClientId") ?? "",
        bitbucketUser: config.string("bitbucketUser") ?? "",
        confluenceSite: config.string("confluenceSite") ?? "",
        confluenceEmail: config.string("confluenceEmail") ?? "",
        googleClientId: config.string("googleClientId") ?? ""
      ),
      mocked: dict.bool("mocked") ?? false
    )
  }

  static func folder(_ dict: [String: Any]) -> LiveFolder? {
    guard let id = dict.string("id"), let kind = dict.string("kind").flatMap(LiveFolderKind.init(rawValue:)) else { return nil }
    return LiveFolder(
      id: id,
      profileId: dict.string("profileId") ?? "",
      kind: kind,
      name: dict.string("name") ?? "",
      sources: dict.strings("sources").compactMap(LiveSourceId.init(rawValue:)),
      groupStacks: dict.bool("groupStacks") ?? true,
      showCompleted: dict.bool("showCompleted") ?? true,
      status: dict.dict("status").flatMap(status),
      hiddenCount: dict.int("hiddenCount") ?? 0
    )
  }

  static func status(_ dict: [String: Any]) -> LiveFolderStatus? {
    guard let state = dict.string("state").flatMap(LiveFolderFetchState.init(rawValue:)) else { return nil }
    let error = dict.dict("error").flatMap { error -> LiveFolderError? in
      guard let source = error.string("source").flatMap(LiveSourceId.init(rawValue:)) else { return nil }
      return LiveFolderError(kind: error.string("kind").flatMap(LiveErrorKind.init(rawValue:)) ?? .other, source: source)
    }
    return LiveFolderStatus(state: state, lastFetch: dict.date("lastFetch"), error: error)
  }

  static func calendarState(_ value: Any?) -> CalendarPaneState {
    let dict = value as? [String: Any] ?? [:]
    let calendars = dict.list("calendars").compactMap { calendar -> SystemCalendarInfo? in
      guard let id = calendar.string("id") else { return nil }
      return SystemCalendarInfo(
        id: id,
        title: calendar.string("title") ?? "",
        color: calendar.string("color") ?? "",
        account: calendar.string("account") ?? "",
        owned: calendar.bool("owned") ?? false
      )
    }
    let options = dict.dict("options") ?? [:]
    let defaults = LiveCalendarOptions()
    return CalendarPaneState(
      access: dict.string("access").flatMap(CalendarAccess.init(rawValue:)) ?? .notDetermined,
      calendars: calendars,
      options: LiveCalendarOptions(
        alertLead: options.string("alertLead") ?? defaults.alertLead,
        alertCondition: options.string("alertCondition") ?? defaults.alertCondition,
        showPreview: options.bool("showPreview") ?? defaults.showPreview,
        showTimeToNext: options.bool("showTimeToNext") ?? defaults.showTimeToNext,
        hiddenCalendarIds: options.strings("hiddenCalendarIds")
      )
    )
  }
}
