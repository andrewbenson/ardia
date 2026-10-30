import Foundation
import Testing

@testable import SolaraLive

@Suite struct SourcesTests {
  let mock = MockServer()

  func connected() async -> Rig {
    let rig = Rig(mock: mock)
    await rig.secrets.setSecret("mock-token", account: "mock:github")
    await rig.engine.setAccount(.github, LiveAccount(login: "octo-dev", name: nil, avatar: nil, connectedAt: 0))
    return rig
  }

  @Test func aGithubFolderFetchesTheSearchThenDetailsInPagesOfTen() async {
    let rig = await connected()
    let id = await rig.engine.createFolder(profileId: "p", kind: .pullRequests, sources: [.github])
    await rig.engine.refreshFolder(id).value
    let fixture = Fixture.decode(GithubResponse.self, "github.json")
    let expected = LiveEngine.order(GitHub.mapGithub(fixture, filters: LiveFilters()))
    #expect(await rig.engine.state.items[id] == expected)
    #expect(await rig.engine.state.status[id] == FolderStatus(state: .idle, lastFetch: rig.clock.now(), error: nil))
    let detailCalls = rig.http.log.current.filter { ($0.bodyText ?? "").contains("LiveFolderDetails") }
    #expect(detailCalls.count == (GitHub.detailIds(fixture, filters: LiveFilters()).count + 9) / 10)
  }

  @Test func aDetailsPageThatFailsOnceIsRetriedAndAFieldErrorEmptiesOnlyThatField() async {
    let rig = await connected()
    let fixture = Fixture.decode(GithubResponse.self, "github.json")
    let target = GitHub.detailIds(fixture, filters: LiveFilters())[1]
    mock.model.with { $0.detailsError = (target, "FIELD") }
    let id = await rig.engine.createFolder(profileId: "p", kind: .pullRequests, sources: [.github])
    await rig.engine.refreshFolder(id).value
    let item = await rig.engine.state.items[id]!.first { $0.id == "github:\(target)" }
    #expect(item?.pr?.checks == [])
    mock.model.with { $0.detailsError = (target, "PAGE") }
    let other = await rig.engine.createFolder(profileId: "p", kind: .pullRequests, sources: [.github])
    await rig.engine.refreshFolder(other).value
    #expect(await rig.engine.state.status[other]?.error?.kind == .other)
    let pageCalls = rig.http.log.current.filter { ($0.bodyText ?? "").contains("LiveFolderDetails") && ($0.bodyText ?? "").contains(target) }
    #expect(pageCalls.count == 3)
  }

  @Test func aMergedPullRequestPlaysItsCompletionThenLeavesAndAReviewedOneSaysSo() async {
    let rig = await connected()
    let id = await rig.engine.createFolder(profileId: "p", kind: .pullRequests, sources: [.github])
    await rig.engine.refreshFolder(id).value
    mock.merge("PR_101")
    mock.drop("PR_88")
    await rig.engine.refreshFolder(id).value
    let state = await rig.engine.state
    #expect(state.completing[id]?.sorted() == ["github:PR_101", "github:PR_88"].sorted())
    #expect(state.items[id]!.contains { $0.id == "github:PR_101" }, "it stays in place while its merge plays")
    #expect(Set(state.completed[id]!.map { "\($0.item.id)=\($0.state.rawValue)" }) == ["github:PR_101=merged", "github:PR_88=reviewed"])
    await rig.clock.advance(by: LiveEngine.completionMs - 1)
    #expect(await rig.engine.state.items[id]!.contains { $0.id == "github:PR_101" })
    await rig.clock.advance(by: 1)
    #expect(await !rig.engine.state.items[id]!.contains { $0.id == "github:PR_101" })
    #expect(await rig.engine.state.completing[id] == [])
  }

  @Test func aSignedOutTokenReadsAsSignBackIn() async {
    let rig = Rig(mock: mock)
    await rig.secrets.setSecret("stale", account: "mock:github")
    let id = await rig.engine.createFolder(profileId: "p", kind: .pullRequests, sources: [.github])
    await rig.engine.refreshFolder(id).value
    #expect(await rig.engine.state.status[id]?.error == FolderError(kind: .signedOut, message: "Signed out", source: .github))
    #expect(await rig.engine.statusText(id) == "Sign back in to GitHub")
    let fresh = await rig.engine.createFolder(profileId: "p", kind: .documents, sources: [.notion])
    await rig.engine.refreshFolder(fresh).value
    #expect(await rig.engine.statusText(fresh) == "Connect Notion in Settings")
  }

  @Test func documentSourcesFetchThroughTheirConnectedAccounts() async throws {
    let rig = Rig(mock: mock)
    let engine = rig.engine
    try await engine.connectNotion(token: " mock-notion ")
    #expect(await engine.state.accounts[.notion]?.login == "Acme")
    rig.auth.respond.with { $0 = { url in
      let state = GoogleAuth.query(url)["state"]!
      return "\(GoogleAuth.redirect)?code=mock-google-code&state=\(state)"
    } }
    try await engine.connectGoogleDrive(clientId: " cid ", clientSecret: "secret")
    #expect(await engine.state.accounts[.gdrive]?.login == "octo@acme.com")
    #expect(await engine.state.config.googleClientId == "cid")
    let id = await engine.newProfileLiveFolder(profileId: "p", kind: .documents)
    #expect(await engine.state.folders[id]?.sources == [.notion, .gdrive])
    await engine.refreshFolder(id).value
    let items = await engine.state.items[id]!
    #expect(Set(items.map(\.source)) == [.notion, .gdrive])
    #expect(items.map(\.updatedAt) == items.map(\.updatedAt).sorted(by: >))
    #expect(await engine.state.unread[id] == [], "the first fetch marks nothing unread")
    #expect(await engine.liveFolderIcon(engine.state.folders[id]!).icon == "symbol:doc.text")
  }

  @Test func anExpiredGoogleTokenIsRefreshedAndStored() async throws {
    let rig = Rig(mock: mock)
    let tokens = GoogleTokens(access_token: "old", refresh_token: "r", expires_at: rig.clock.now() + 59_000, client_secret: "s")
    await rig.secrets.setSecret(try LiveJSON.text(tokens), account: "mock:gdrive")
    let id = await rig.engine.createFolder(profileId: "p", kind: .documents, sources: [.gdrive])
    await rig.engine.refreshFolder(id).value
    #expect(await rig.engine.state.items[id]?.count == 2)
    let stored = try LiveJSON.decode(GoogleTokens.self, from: await rig.secrets.secret(account: "mock:gdrive")!)
    #expect(stored.access_token == "mock-google-access")
    #expect(stored.expires_at == rig.clock.now() + 3_600_000)
    #expect(rig.http.log.current.first?.bodyText?.contains("grant_type=refresh_token") == true)
  }

  @Test func googleSignInRejectsARedirectFromAnotherRequest() async {
    let rig = Rig(mock: mock)
    rig.auth.respond.with { $0 = { _ in "\(GoogleAuth.redirect)?code=c&state=wrong" } }
    await #expect(throws: LiveAuthError("Sign-in didn't match this request")) {
      try await rig.engine.connectGoogleDrive(clientId: "c", clientSecret: "s")
    }
    rig.auth.respond.with { $0 = { url in "\(GoogleAuth.redirect)?error=access_denied&state=\(GoogleAuth.query(url)["state"]!)" } }
    await #expect(throws: LiveAuthError("access_denied")) { try await rig.engine.connectGoogleDrive(clientId: "c", clientSecret: "s") }
    let opened = rig.auth.opened.current.last!
    let q = GoogleAuth.query(opened)
    #expect(opened.hasPrefix("\(MockServer.base)/google/auth?client_id=c&redirect_uri=http%3A%2F%2F127.0.0.1%3A53682%2Fardia-oauth"))
    #expect(q["code_challenge"]?.count == 64 && q["state"]?.count == 24 && q["code_challenge_method"] == "plain")
  }

  @Test func theDeviceFlowPollsAtItsIntervalBacksOffOnSlowDownAndConnects() async throws {
    let rig = Rig(mock: mock)
    mock.model.with { $0.deviceResponses = [["error": "authorization_pending"], ["error": "slow_down", "interval": 6]] }
    let flow = try await rig.engine.startGithubDeviceFlow(clientId: "cid")
    #expect(flow.userCode == "WDJB-MJHT")
    #expect(flow.expiresAt == rig.clock.now() + 900_000)
    await settle()
    #expect(rig.clock.pending == [rig.clock.now() + 1000])
    await rig.clock.advance(by: 1000)
    await rig.clock.advance(by: 1000)
    #expect(rig.clock.pending == [rig.clock.now() + 6000])
    mock.model.with { $0.approved = true }
    await rig.clock.advance(by: 6000)
    try await flow.done.value
    #expect(await rig.engine.state.accounts[.github]?.login == "octo-dev")
    #expect(await rig.secrets.secret(account: "mock:github") == "mock-token")
  }

  @Test func aCancelledOrDeniedDeviceFlowSaysWhy() async throws {
    let rig = Rig(mock: mock)
    let flow = try await rig.engine.startGithubDeviceFlow(clientId: "cid")
    await settle()
    flow.cancel()
    await #expect(throws: LiveError(.signedOut, "Cancelled")) { try await flow.done.value }
    mock.model.with { $0.deviceResponses = [["error": "access_denied"]] }
    let denied = try await rig.engine.startGithubDeviceFlow(clientId: "cid")
    await settle()
    await rig.clock.advance(by: 1000)
    await #expect(throws: LiveError(.signedOut, "Access was denied")) { try await denied.done.value }
  }
}
