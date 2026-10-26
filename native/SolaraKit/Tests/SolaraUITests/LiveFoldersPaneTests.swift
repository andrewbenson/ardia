import AppKit
import Foundation
import SwiftUI
import Testing
@testable import SolaraUI

@MainActor
final class FakeLiveFoldersServices: LiveFoldersServices {
  static let now = Date()

  var state = LiveFoldersState(
    folders: [
      LiveFolder(
        id: "lf-1", profileId: "default", kind: .pullRequests, name: "Pull Requests", sources: [.github, .bitbucket],
        groupStacks: true, showCompleted: false,
        status: LiveFolderStatus(state: .idle, lastFetch: now.addingTimeInterval(-4 * 60), error: nil), hiddenCount: 2
      ),
      LiveFolder(
        id: "lf-2", profileId: "work", kind: .documents, name: "Docs", sources: [.notion, .gdrive],
        groupStacks: true, showCompleted: true,
        status: LiveFolderStatus(state: .error, lastFetch: nil, error: LiveFolderError(kind: .signedOut, source: .notion)), hiddenCount: 0
      ),
      LiveFolder(
        id: "lf-3", profileId: "work", kind: .pullRequests, name: "Team PRs", sources: [.github],
        groupStacks: false, showCompleted: true, status: nil, hiddenCount: 0
      ),
    ],
    accounts: [
      .github: LiveAccount(login: "octocat", name: "Mona Lisa"),
      .notion: LiveAccount(login: "Acme", name: "Acme"),
    ],
    config: LiveConfig(githubClientId: "Iv1.abc", bitbucketUser: "me@example.com", confluenceSite: "https://acme.atlassian.net")
  )
  var calls: [String] = []
  var failConnect: String?
  let changes = AsyncStream<LiveFoldersState>.makeStream()
  var changeRequests = 0

  func liveFoldersState() async -> LiveFoldersState { state }
  func liveFoldersChanges() -> AsyncStream<LiveFoldersState> {
    changeRequests += 1
    return changes.stream
  }
  func refreshFolder(_ id: String) async { calls.append("refresh \(id)") }
  func deleteFolder(_ id: String) { calls.append("delete \(id)") }
  func updateFolder(_ id: String, groupStacks: Bool?, showCompleted: Bool?) {
    calls.append("update \(id) groupStacks=\(groupStacks.map(String.init) ?? "nil") showCompleted=\(showCompleted.map(String.init) ?? "nil")")
  }
  func disconnect(_ source: LiveSourceId) async { calls.append("disconnect \(source.rawValue)") }
  func connectGithub(token: String) async throws {
    calls.append("github \(token)")
    if let failConnect { throw LiveConnectError(failConnect) }
  }
  func setGithubClientId(_ clientId: String) { calls.append("clientId \(clientId)") }
  func startGithubDeviceFlow(clientId: String) async throws -> LiveDeviceFlow {
    calls.append("device \(clientId)")
    return LiveDeviceFlow(id: "flow-1", userCode: "WDJB-MJHT", verificationUri: "https://github.com/login/device")
  }
  func finishGithubDeviceFlow(_ flow: LiveDeviceFlow) async throws { calls.append("finish \(flow.id)") }
  func cancelGithubDeviceFlow(_ flow: LiveDeviceFlow) { calls.append("cancel \(flow.id)") }
  func connectBitbucket(user: String, token: String) async throws { calls.append("bitbucket \(user)") }
  func connectNotion(token: String) async throws { calls.append("notion") }
  func connectConfluence(site: String, email: String, token: String) async throws { calls.append("confluence \(site)") }
  func connectGoogleDrive(clientId: String, clientSecret: String) async throws { calls.append("gdrive \(clientId)") }
  func copyText(_ text: String) { calls.append("copy \(text)") }
  func openInBrowser(_ url: String) { calls.append("open \(url)") }
  func favicon(site: String) async -> NSImage? {
    let symbol: String
    switch site {
    case LiveSourceId.github.site: symbol = "chevron.left.forwardslash.chevron.right"
    case LiveSourceId.bitbucket.site: symbol = "shippingbox.fill"
    case LiveSourceId.notion.site: symbol = "n.square.fill"
    case LiveSourceId.confluence.site: symbol = "doc.richtext"
    default: symbol = "triangle"
    }
    return NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
  }
}

@MainActor
struct LiveFoldersPaneTests {
  static func loaded(_ services: FakeLiveFoldersServices = FakeLiveFoldersServices()) async -> (SettingsContext, LiveFoldersPaneModel, FakeLiveFoldersServices) {
    let (context, store) = SettingsFixture.context()
    let model = LiveFoldersPaneModel(services: services, store: store)
    context.panes[.liveFolders] = model
    await model.prepare(SettingsPlace(pane: .liveFolders))
    return (context, model, services)
  }

  @Test func statusTextFollowsTheEngine() {
    let now = FakeLiveFoldersServices.now
    func folder(_ status: LiveFolderStatus?, hidden: Int = 0) -> LiveFolder {
      LiveFolder(id: "f", profileId: "default", kind: .pullRequests, name: "PRs", sources: [.github], groupStacks: true, showCompleted: true, status: status, hiddenCount: hidden)
    }
    #expect(LiveFoldersText.statusText(folder(nil), now: now) == "Loading…")
    #expect(LiveFoldersText.statusText(folder(LiveFolderStatus(state: .initializing, lastFetch: nil, error: nil)), now: now) == "Loading…")
    #expect(LiveFoldersText.statusText(folder(LiveFolderStatus(state: .updating, lastFetch: now, error: nil)), now: now) == "Updating…")
    #expect(LiveFoldersText.statusText(folder(LiveFolderStatus(state: .idle, lastFetch: nil, error: nil)), now: now) == "Not updated yet")
    #expect(LiveFoldersText.statusText(folder(LiveFolderStatus(state: .idle, lastFetch: now.addingTimeInterval(-30), error: nil)), now: now) == "Updated just now")
    #expect(LiveFoldersText.statusText(folder(LiveFolderStatus(state: .idle, lastFetch: now.addingTimeInterval(-59 * 60), error: nil)), now: now) == "Updated 59 min ago")
    #expect(LiveFoldersText.statusText(folder(LiveFolderStatus(state: .idle, lastFetch: now.addingTimeInterval(-150 * 60), error: nil)), now: now) == "Updated 2 hr ago")
    #expect(LiveFoldersText.statusText(folder(LiveFolderStatus(state: .idle, lastFetch: now.addingTimeInterval(-60), error: nil), hidden: 3), now: now) == "Updated 1 min ago · 3 hidden until you refresh")
    #expect(LiveFoldersText.statusText(folder(LiveFolderStatus(state: .error, lastFetch: now, error: LiveFolderError(kind: .rateLimited, source: .github))), now: now) == "GitHub rate limit exceeded. Try again in a few minutes.")
  }

  @Test func errorTextNamesTheSource() {
    #expect(LiveFoldersText.errorText(.notConfigured, .gdrive) == "Connect Google Drive in Settings")
    #expect(LiveFoldersText.errorText(.signedOut, .notion) == "Sign back in to Notion")
    #expect(LiveFoldersText.errorText(.sso, .github) == "GitHub needs Single Sign-On for this organization")
    #expect(LiveFoldersText.errorText(.network, .confluence) == "Couldn't connect to Confluence")
    #expect(LiveFoldersText.errorText(.other, .bitbucket) == "We're having trouble connecting to Bitbucket")
  }

  @Test func connectedAsShowsLoginOnlyForGithubAndDrive() {
    #expect(LiveFoldersText.connectedAs(.github, LiveAccount(login: "octocat", name: "Mona")) == "Mona (octocat)")
    #expect(LiveFoldersText.connectedAs(.gdrive, LiveAccount(login: "me@x.com", name: "Me")) == "Me (me@x.com)")
    #expect(LiveFoldersText.connectedAs(.bitbucket, LiveAccount(login: "123", name: "Me")) == "Me")
    #expect(LiveFoldersText.connectedAs(.notion, LiveAccount(login: "Acme", name: "Acme")) == "Acme")
    #expect(LiveFoldersText.connectedAs(.github, LiveAccount(login: "octocat", name: nil)) == "octocat")
    #expect(LiveFoldersText.sourceDescription(.confluence, nil) == "Pages you created, edited or watch.")
    #expect(LiveFoldersText.sourceDescription(.github, LiveAccount(login: "octocat", name: nil)) == "Connected as octocat")
  }

  @Test func folderDescriptionNamesProfileSourcesAndStatus() async {
    let (_, model, services) = await Self.loaded()
    let first = services.state.folders[0]
    #expect(LiveFoldersText.folderDescription(first, profileName: model.profileName(first), now: FakeLiveFoldersServices.now) == "Personal · GitHub, Bitbucket · Updated 4 min ago · 2 hidden until you refresh")
    var orphan = first
    orphan.profileId = "gone"
    #expect(model.profileName(orphan) == "Profile")
  }

  @Test func onlyTheFirstPullRequestFolderCarriesTheSearchAnchors() async {
    let (_, model, _) = await Self.loaded()
    #expect(model.anchoredOptionsFolderId == "lf-1")
  }

  @Test func commandsReachTheEngine() async {
    let (_, model, services) = await Self.loaded()
    let folder = model.folders[0]
    model.setGroupStacks(folder, false)
    model.setShowCompleted(folder, true)
    #expect(model.folders[0].groupStacks == false)
    #expect(model.folders[0].showCompleted == true)
    model.delete(model.folders[1])
    #expect(model.folders.map(\.id) == ["lf-1", "lf-3"])
    model.disconnect(.github)
    #expect(model.account(.github) == nil)
    model.refresh(folder)
    await LiveSettingsWait.until { services.calls.contains("refresh lf-1") && services.calls.contains("disconnect github") }
    #expect(services.calls.contains("update lf-1 groupStacks=false showCompleted=nil"))
    #expect(services.calls.contains("update lf-1 groupStacks=nil showCompleted=true"))
    #expect(services.calls.contains("delete lf-2"))
    #expect(services.calls.contains("disconnect github"))
    #expect(services.calls.contains("refresh lf-1"))
  }

  @Test func engineChangesReplaceTheStateAndSubscribeOnce() async {
    let (_, model, services) = await Self.loaded()
    await model.prepare(SettingsPlace(pane: .liveFolders))
    #expect(services.changeRequests == 1)
    var next = services.state
    next.folders = []
    next.mocked = true
    services.changes.continuation.yield(next)
    await LiveSettingsWait.until { model.state?.mocked == true }
    #expect(model.folders.isEmpty)
    #expect(model.state?.mocked == true)
  }

  @Test func connectRunnerKeepsErrorsAndFinishesOnSuccess() async {
    let runner = LiveFoldersConnectRun()
    runner.run { throw LiveConnectError("GitHub didn't accept the token") }
    #expect(runner.busy)
    await LiveSettingsWait.until { !runner.busy }
    #expect(!runner.busy)
    #expect(runner.error == "GitHub didn't accept the token")
    #expect(!runner.finished)
    runner.run {}
    await LiveSettingsWait.until { runner.finished }
    #expect(runner.error == nil)
    #expect(runner.finished)
  }

  @Test(.enabled(if: Snapshot.directory != nil))
  func rendersLiveFolders() async throws {
    let directory = try #require(Snapshot.directory)
    let (context, model, services) = await Self.loaded()
    try await Snapshot.renderPanes(context, [.liveFolders])
    for dark in [false, true] {
      let scheme = dark ? "dark" : "light"
      for source in LiveSourceId.allCases {
        let sheet = LiveFoldersConnectSheet(model: model, source: source, appName: "Solara").environment(\.settingsContext, context)
        try await Snapshot.render(sheet, size: NSSize(width: 460, height: source == .github ? 420 : 330), dark: dark, to: directory.appendingPathComponent("liveFolders-connect-\(source.rawValue)-\(scheme).png"))
      }
      let flow = LiveDeviceFlow(id: "flow-1", userCode: "WDJB-MJHT", verificationUri: "https://github.com/login/device")
      let device = LiveFoldersGithubConnect(model: model, runner: LiveFoldersConnectRun(), appName: "Solara", clientId: "Iv1.abc", flow: flow).padding(20).frame(width: 460)
      try await Snapshot.render(device, size: NSSize(width: 460, height: 200), dark: dark, to: directory.appendingPathComponent("liveFolders-connect-github-device-\(scheme).png"))
    }
    var empty = services.state
    empty.folders = []
    empty.accounts = [:]
    empty.mocked = true
    model.state = empty
    try await Snapshot.renderPanes(context, [], places: [SettingsPlace(pane: .liveFolders)], named: { _ in "liveFolders-empty" })
  }
}
