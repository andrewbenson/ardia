import AppKit
import Observation
import SwiftUI

public enum LiveSourceId: String, CaseIterable, Sendable, Identifiable {
  case github
  case bitbucket
  case notion
  case confluence
  case gdrive

  public var id: String { rawValue }

  public var name: String {
    switch self {
    case .github: "GitHub"
    case .bitbucket: "Bitbucket"
    case .notion: "Notion"
    case .confluence: "Confluence"
    case .gdrive: "Google Drive"
    }
  }

  public var site: String {
    switch self {
    case .github: "https://github.com"
    case .bitbucket: "https://bitbucket.org"
    case .notion: "https://www.notion.so"
    case .confluence: "https://www.atlassian.com"
    case .gdrive: "https://drive.google.com"
    }
  }

  var settingsAnchor: String {
    switch self {
    case .github: "liveFolders.github"
    case .bitbucket: "liveFolders.bitbucket"
    case .notion: "liveFolders.notion"
    case .confluence: "liveFolders.confluence"
    case .gdrive: "liveFolders.gdrive"
    }
  }

  var settingsDescription: String {
    switch self {
    case .github: "Your open pull requests and the ones waiting for your review, with checks and conflicts."
    case .bitbucket: "Your open pull requests on Bitbucket Cloud, with build status."
    case .notion: "Pages recently edited in your workspace."
    case .confluence: "Pages you created, edited or watch."
    case .gdrive: "Documents recently changed in your Drive."
    }
  }
}

public enum LiveFolderKind: String, Sendable {
  case pullRequests
  case documents
}

public struct LiveAccount: Sendable, Equatable {
  public var login: String
  public var name: String?

  public init(login: String, name: String?) {
    self.login = login
    self.name = name
  }
}

public enum LiveErrorKind: String, Sendable {
  case signedOut
  case sso
  case rateLimited
  case network
  case notConfigured
  case other
}

public struct LiveFolderError: Sendable, Equatable {
  public var kind: LiveErrorKind
  public var source: LiveSourceId

  public init(kind: LiveErrorKind, source: LiveSourceId) {
    self.kind = kind
    self.source = source
  }
}

public enum LiveFolderFetchState: String, Sendable {
  case initializing
  case idle
  case updating
  case error
}

public struct LiveFolderStatus: Sendable, Equatable {
  public var state: LiveFolderFetchState
  public var lastFetch: Date?
  public var error: LiveFolderError?

  public init(state: LiveFolderFetchState, lastFetch: Date?, error: LiveFolderError?) {
    self.state = state
    self.lastFetch = lastFetch
    self.error = error
  }
}

public struct LiveFolder: Sendable, Equatable, Identifiable {
  public var id: String
  public var profileId: String
  public var kind: LiveFolderKind
  public var name: String
  public var sources: [LiveSourceId]
  public var groupStacks: Bool
  public var showCompleted: Bool
  public var status: LiveFolderStatus?
  public var hiddenCount: Int

  public init(id: String, profileId: String, kind: LiveFolderKind, name: String, sources: [LiveSourceId], groupStacks: Bool, showCompleted: Bool, status: LiveFolderStatus?, hiddenCount: Int) {
    self.id = id
    self.profileId = profileId
    self.kind = kind
    self.name = name
    self.sources = sources
    self.groupStacks = groupStacks
    self.showCompleted = showCompleted
    self.status = status
    self.hiddenCount = hiddenCount
  }
}

public struct LiveConfig: Sendable, Equatable {
  public var githubClientId: String
  public var bitbucketUser: String
  public var confluenceSite: String
  public var confluenceEmail: String
  public var googleClientId: String

  public init(githubClientId: String = "", bitbucketUser: String = "", confluenceSite: String = "", confluenceEmail: String = "", googleClientId: String = "") {
    self.githubClientId = githubClientId
    self.bitbucketUser = bitbucketUser
    self.confluenceSite = confluenceSite
    self.confluenceEmail = confluenceEmail
    self.googleClientId = googleClientId
  }
}

public struct LiveFoldersState: Sendable, Equatable {
  public var folders: [LiveFolder]
  public var accounts: [LiveSourceId: LiveAccount]
  public var config: LiveConfig
  public var mocked: Bool

  public init(folders: [LiveFolder], accounts: [LiveSourceId: LiveAccount], config: LiveConfig, mocked: Bool = false) {
    self.folders = folders
    self.accounts = accounts
    self.config = config
    self.mocked = mocked
  }
}

public struct LiveDeviceFlow: Sendable, Equatable, Identifiable {
  public var id: String
  public var userCode: String
  public var verificationUri: String

  public init(id: String, userCode: String, verificationUri: String) {
    self.id = id
    self.userCode = userCode
    self.verificationUri = verificationUri
  }
}

public struct LiveConnectError: LocalizedError, Sendable {
  public var message: String

  public init(_ message: String) {
    self.message = message
  }

  public var errorDescription: String? { message }
}

@MainActor
public protocol LiveFoldersServices: AnyObject {
  func liveFoldersState() async -> LiveFoldersState
  func liveFoldersChanges() -> AsyncStream<LiveFoldersState>
  func refreshFolder(_ id: String) async
  func deleteFolder(_ id: String)
  func updateFolder(_ id: String, groupStacks: Bool?, showCompleted: Bool?)
  func disconnect(_ source: LiveSourceId) async
  func connectGithub(token: String) async throws
  func setGithubClientId(_ clientId: String)
  func startGithubDeviceFlow(clientId: String) async throws -> LiveDeviceFlow
  func finishGithubDeviceFlow(_ flow: LiveDeviceFlow) async throws
  func cancelGithubDeviceFlow(_ flow: LiveDeviceFlow)
  func connectBitbucket(user: String, token: String) async throws
  func connectNotion(token: String) async throws
  func connectConfluence(site: String, email: String, token: String) async throws
  func connectGoogleDrive(clientId: String, clientSecret: String) async throws
  func copyText(_ text: String)
  func openInBrowser(_ url: String)
  func favicon(site: String) async -> NSImage?
}

enum LiveFoldersText {
  static func connectedAs(_ source: LiveSourceId, _ account: LiveAccount) -> String {
    guard let name = account.name, !name.isEmpty, name != account.login else { return account.login }
    return source == .github || source == .gdrive ? "\(name) (\(account.login))" : name
  }

  static func sourceDescription(_ source: LiveSourceId, _ account: LiveAccount?) -> String {
    guard let account else { return source.settingsDescription }
    return "Connected as \(connectedAs(source, account))"
  }

  static func statusText(_ folder: LiveFolder, now: Date) -> String {
    let fetch = fetchText(folder.status, now: now)
    return folder.hiddenCount > 0 ? "\(fetch) · \(folder.hiddenCount) hidden until you refresh" : fetch
  }

  static func fetchText(_ status: LiveFolderStatus?, now: Date) -> String {
    guard let status, status.state != .initializing else { return "Loading…" }
    if status.state == .updating { return "Updating…" }
    if let error = status.error { return errorText(error.kind, error.source) }
    guard let lastFetch = status.lastFetch else { return "Not updated yet" }
    let minutes = Int((now.timeIntervalSince(lastFetch) / 60).rounded(.down))
    if minutes < 1 { return "Updated just now" }
    if minutes < 60 { return "Updated \(minutes) min ago" }
    return "Updated \(minutes / 60) hr ago"
  }

  static func errorText(_ kind: LiveErrorKind, _ source: LiveSourceId) -> String {
    let name = source.name
    switch kind {
    case .notConfigured: return "Connect \(name) in Settings"
    case .signedOut: return "Sign back in to \(name)"
    case .sso: return "\(name) needs Single Sign-On for this organization"
    case .rateLimited: return "\(name) rate limit exceeded. Try again in a few minutes."
    case .network: return "Couldn't connect to \(name)"
    case .other: return "We're having trouble connecting to \(name)"
    }
  }

  static func folderDescription(_ folder: LiveFolder, profileName: String, now: Date) -> String {
    "\(profileName) · \(folder.sources.map(\.name).joined(separator: ", ")) · \(statusText(folder, now: now))"
  }
}

@MainActor
@Observable
public final class LiveFoldersPaneModel: SettingsPaneProvider {
  @ObservationIgnored let services: LiveFoldersServices
  @ObservationIgnored let store: SettingsStoreSource
  @ObservationIgnored private var listening: Task<Void, Never>?
  var state: LiveFoldersState?
  var icons: [LiveSourceId: NSImage] = [:]

  public init(services: LiveFoldersServices, store: SettingsStoreSource) {
    self.services = services
    self.store = store
  }

  public func isLoaded(_ place: SettingsPlace) -> Bool { state != nil }

  public func prepare(_ place: SettingsPlace) async {
    listen()
    if state == nil { state = await services.liveFoldersState() }
    await loadIcons()
  }

  public func view(_ place: SettingsPlace) -> AnyView {
    AnyView(LiveFoldersPane(model: self))
  }

  private func listen() {
    guard listening == nil else { return }
    let changes = services.liveFoldersChanges()
    listening = Task { [weak self] in
      for await next in changes {
        guard let self else { return }
        self.state = next
      }
    }
  }

  private func loadIcons() async {
    for source in LiveSourceId.allCases where icons[source] == nil {
      if let image = await services.favicon(site: source.site) { icons[source] = image }
    }
  }

  var folders: [LiveFolder] { state?.folders ?? [] }

  var anchoredOptionsFolderId: String? { folders.first { $0.kind == .pullRequests }?.id }

  func account(_ source: LiveSourceId) -> LiveAccount? { state?.accounts[source] }

  func profileName(_ folder: LiveFolder) -> String {
    store.profiles.first { $0.id == folder.profileId }?.name ?? "Profile"
  }

  func setGroupStacks(_ folder: LiveFolder, _ on: Bool) {
    patchFolder(folder.id) { $0.groupStacks = on }
    services.updateFolder(folder.id, groupStacks: on, showCompleted: nil)
  }

  func setShowCompleted(_ folder: LiveFolder, _ on: Bool) {
    patchFolder(folder.id) { $0.showCompleted = on }
    services.updateFolder(folder.id, groupStacks: nil, showCompleted: on)
  }

  func refresh(_ folder: LiveFolder) {
    Task { await services.refreshFolder(folder.id) }
  }

  func delete(_ folder: LiveFolder) {
    state?.folders.removeAll { $0.id == folder.id }
    services.deleteFolder(folder.id)
  }

  func disconnect(_ source: LiveSourceId) {
    state?.accounts[source] = nil
    Task { await services.disconnect(source) }
  }

  private func patchFolder(_ id: String, _ change: (inout LiveFolder) -> Void) {
    guard let index = state?.folders.firstIndex(where: { $0.id == id }) else { return }
    change(&state!.folders[index])
  }
}

struct LiveFoldersPane: View {
  @Environment(\.settingsContext) private var context
  let model: LiveFoldersPaneModel
  @State private var connecting: LiveSourceId?

  var body: some View {
    SettingsForm {
      SettingsSection(
        description: "Right-click empty space in the sidebar and choose New Live Folder to add one. Live folders refresh every few minutes; items open as tabs that stay in the folder.",
        anchor: "liveFolders.folders"
      ) {
        EmptyView()
      }

      ForEach(model.folders) { folder in
        LiveFoldersFolderSection(model: model, folder: folder, anchored: folder.id == model.anchoredOptionsFolderId)
      }

      SettingsSection("Pull Requests") {
        LiveFoldersSourceRow(model: model, source: .github, connecting: $connecting)
        LiveFoldersSourceRow(model: model, source: .bitbucket, connecting: $connecting)
      }

      SettingsSection("Documents") {
        LiveFoldersSourceRow(model: model, source: .notion, connecting: $connecting)
        LiveFoldersSourceRow(model: model, source: .confluence, connecting: $connecting)
        LiveFoldersSourceRow(model: model, source: .gdrive, connecting: $connecting)
      }

      if model.state?.mocked == true {
        Section {
          Text("Development build: services are served by ARDIA_LIVE_MOCK.")
            .font(.caption)
            .foregroundStyle(Color(red: 0xD2 / 255, green: 0x99 / 255, blue: 0x22 / 255))
        }
      }
    }
    .sheet(item: $connecting) { source in
      LiveFoldersConnectSheet(model: model, source: source, appName: context?.appName ?? "")
    }
  }
}

struct LiveFoldersFolderSection: View {
  @Environment(\.settingsContext) private var context
  let model: LiveFoldersPaneModel
  let folder: LiveFolder
  let anchored: Bool

  var body: some View {
    Section {
      TimelineView(.everyMinute) { timeline in
        SettingRow(title: folder.name, description: LiveFoldersText.folderDescription(folder, profileName: model.profileName(folder), now: timeline.date)) {
          HStack(spacing: 6) {
            Button("Refresh") { model.refresh(folder) }
            Button("Delete", role: .destructive) { model.delete(folder) }
          }
        }
      }
      if folder.kind == .pullRequests {
        option("liveFolders.groupStacks", isOn: Binding(get: { folder.groupStacks }, set: { model.setGroupStacks(folder, $0) }))
        option("liveFolders.showCompleted", isOn: Binding(get: { folder.showCompleted }, set: { model.setShowCompleted(folder, $0) }))
      }
    }
  }

  private func option(_ id: String, isOn: Binding<Bool>) -> some View {
    let entry = context?.index.entry(id)
    return SettingRow(anchored ? id : nil, title: entry?.title, description: entry.flatMap(\.description).map(RowDescription.text) ?? .none) {
      Toggle("", isOn: isOn)
        .labelsHidden()
        .toggleStyle(.switch)
    }
  }
}

struct LiveFoldersSourceIcon: View {
  let image: NSImage?
  let size: CGFloat

  var body: some View {
    Group {
      if let image {
        Image(nsImage: image)
          .resizable()
          .interpolation(.high)
      } else {
        Image(systemName: "globe")
          .resizable()
          .foregroundStyle(.secondary)
      }
    }
    .aspectRatio(contentMode: .fit)
    .frame(width: size, height: size)
  }
}

struct LiveFoldersSourceRow: View {
  @Environment(\.settingsContext) private var context
  let model: LiveFoldersPaneModel
  let source: LiveSourceId
  @Binding var connecting: LiveSourceId?

  var body: some View {
    let account = model.account(source)
    SettingsAnchor(source.settingsAnchor) {
      LabeledContent {
        if account != nil {
          Button("Disconnect") { model.disconnect(source) }
        } else {
          Button("Connect…") { connecting = source }
        }
      } label: {
        HStack(spacing: 10) {
          LiveFoldersSourceIcon(image: model.icons[source], size: 18)
          VStack(alignment: .leading, spacing: 2) {
            Text(context?.index.entry(source.settingsAnchor)?.title ?? source.name)
            Text(LiveFoldersText.sourceDescription(source, account))
              .font(.subheadline)
              .foregroundStyle(.secondary)
              .fixedSize(horizontal: false, vertical: true)
          }
        }
      }
    }
  }
}
