import AppKit
import SwiftUI
import Testing
@testable import SolaraUI

@MainActor
final class FakePrivacyServices: PrivacyServices {
  var blocker: ContentBlockerState? = ContentBlockerState(
    enabled: true,
    version: "1.62.0",
    lists: [
      FilterList(id: "easylist", title: "EasyList", category: .ads, enabled: true, defaultOn: true, filters: 71_204),
      FilterList(id: "ublock-filters", title: "uBlock filters – Ads", category: .ads, enabled: true, defaultOn: true, filters: 9_870),
      FilterList(id: "adguard-ads", title: "AdGuard Base", category: .ads, enabled: false, defaultOn: false, filters: 101_532),
      FilterList(id: "easyprivacy", title: "EasyPrivacy", category: .trackers, enabled: true, defaultOn: true, filters: 53_118),
      FilterList(id: "adguard-tracking", title: "AdGuard Tracking Protection", category: .trackers, enabled: false, defaultOn: false, filters: 1),
      FilterList(id: "fanboy-cookiemonster", title: "EasyList Cookie", category: .cookies, enabled: false, defaultOn: false, filters: 24_660),
      FilterList(id: "adguard-cookies", title: "AdGuard Cookie Notices", category: .cookies, enabled: false, defaultOn: false, filters: 18_002),
      FilterList(id: "fanboy-annoyance", title: "EasyList Annoyances", category: .annoyances, enabled: false, defaultOn: false, filters: 42_310),
      FilterList(id: "urlhaus", title: "Online Malicious URL Blocklist", category: .security, enabled: true, defaultOn: true, filters: 9_114),
      FilterList(id: "easylist-germany", title: "EasyList Germany", category: .regional, enabled: false, defaultOn: false, filters: 14_871),
    ],
    allowedHosts: ["news.ycombinator.com", "example.org"],
    networkFilters: 182_431,
    cosmeticFilters: 96_207
  )
  var origins: [String: [String]] = [
    "default": ["https://meet.google.com", "https://github.com", "http://localhost:3000"],
    "work": [],
  ]
  var allowances: [String: [ExternalAppAllowance]] = [
    "default": [
      ExternalAppAllowance(origin: "https://zoom.us", scheme: "zoommtg", app: "zoom.us", icon: nil),
      ExternalAppAllowance(origin: "https://open.spotify.com", scheme: "spotify", app: nil, icon: nil),
    ],
  ]
  var zoom: [String: [String: Double]] = [
    "default": ["github.com": 1.1, "docs.swift.org": 0.9, "news.ycombinator.com": 1.25],
  ]
  var siteSettings: [SiteSettingType: SiteSettingState] = [
    .popups: SiteSettingState(value: .block, isDefault: true),
    .camera: SiteSettingState(value: .allow, isDefault: false),
    .microphone: SiteSettingState(value: .allow, isDefault: false),
    .location: SiteSettingState(value: .ask, isDefault: true),
    .notifications: SiteSettingState(value: .block, isDefault: false),
    .sensors: SiteSettingState(value: .allow, isDefault: true),
    .javascript: SiteSettingState(value: .allow, isDefault: true),
    .fileSystem: SiteSettingState(value: .ask, isDefault: true),
  ]
  var clearResult = ClearSiteDataResult(cookies: 3, storage: true)
  var calls: [String] = []
  var failListCalls = false
  private var changeContinuations: [AsyncStream<Void>.Continuation] = []

  func contentBlocker() async -> ContentBlockerState? { blocker }

  func contentBlockerChanges() -> AsyncStream<Void> {
    AsyncStream { changeContinuations.append($0) }
  }

  func emitChange() { for continuation in changeContinuations { continuation.yield() } }

  func setContentBlockerEnabled(_ on: Bool) async throws {
    calls.append("enabled \(on)")
    blocker?.enabled = on
  }

  func setFilterListEnabled(_ id: String, enabled: Bool) async throws {
    calls.append("list \(id) \(enabled)")
    if failListCalls { throw CancellationError() }
    guard let index = blocker?.lists.firstIndex(where: { $0.id == id }) else { return }
    blocker?.lists[index].enabled = enabled
  }

  func setContentBlockerAllowed(host: String, allowed: Bool) async throws {
    calls.append("allowed \(host) \(allowed)")
    if !allowed { blocker?.allowedHosts.removeAll { $0 == host } }
  }

  func siteSettingsOrigins(profile: String) async -> [String] {
    calls.append("origins \(profile)")
    return origins[profile] ?? []
  }

  func siteSettings(profile: String, origin: String) async -> [SiteSettingType: SiteSettingState]? { siteSettings }

  func setSiteSetting(profile: String, origin: String, type: SiteSettingType, value: SiteSettingValue) async {
    calls.append("site \(profile) \(origin) \(type.rawValue) \(value.rawValue)")
    siteSettings[type] = value == .default ? SiteSettingState(value: .ask, isDefault: true) : SiteSettingState(value: value, isDefault: false)
  }

  func resetSiteSettings(profile: String, origin: String) async {
    calls.append("reset \(profile) \(origin)")
    siteSettings = [:]
  }

  func clearSiteData(profile: String, origin: String) async -> ClearSiteDataResult {
    calls.append("clear \(profile) \(origin)")
    return clearResult
  }

  func externalAppAllowances(profile: String) async -> [ExternalAppAllowance] { allowances[profile] ?? [] }

  func removeExternalAppAllowance(profile: String, origin: String, scheme: String) async {
    calls.append("removeApp \(profile) \(origin) \(scheme)")
    allowances[profile]?.removeAll { $0.origin == origin && $0.scheme == scheme }
  }

  func zoomLevels(profile: String) async -> [String: Double] { zoom[profile] ?? [:] }

  func setZoom(profile: String, host: String, zoom level: Double) async {
    calls.append("zoom \(profile) \(host) \(level)")
    if level == 1 { zoom[profile]?[host] = nil }
  }

  func favicon(url: String, profile: String) async -> NSImage? {
    guard url.contains("github") else { return nil }
    return NSImage(size: NSSize(width: 32, height: 32), flipped: false) { rect in
      NSColor.systemPurple.setFill()
      NSBezierPath(ovalIn: rect).fill()
      return true
    }
  }
}

@MainActor
final class FakeDiagnostics: DiagnosticsSharingServices {
  var available = true
  var sharing = false
  var sources: [String] = []
  let telemetryHost = "telemetry.solara.example"
  let updateHost = "updates.solara.example"
  let switchFile = "updates.solara.example/switches.json"

  func setSharing(_ on: Bool, source: String) {
    sharing = on
    sources.append(source)
  }
}

@MainActor
struct PrivacyPaneTests {
  static func make(diagnostics: DiagnosticsSharingServices? = FakeDiagnostics()) async -> (PrivacyPaneModel, FakePrivacyServices, SettingsContext, FakeSettingsStore) {
    let (context, store) = SettingsFixture.context()
    let services = FakePrivacyServices()
    let model = PrivacyPaneModel(services: services, diagnostics: diagnostics, store: store)
    context.panes[.privacy] = model
    await model.prepare(SettingsPlace(pane: .privacy))
    return (model, services, context, store)
  }

  static func list(_ id: String, _ category: FilterListCategory, enabled: Bool = false, defaultOn: Bool = false) -> FilterList {
    FilterList(id: id, title: id, category: category, enabled: enabled, defaultOn: defaultOn, filters: 10)
  }

  @Test func loadsEverySourceForTheDefaultProfile() async {
    let (model, services, _, _) = await Self.make()
    #expect(model.isLoaded(SettingsPlace(pane: .privacy)))
    #expect(model.origins["default"]?.count == 3)
    #expect(model.appLinks["default"]?.count == 2)
    #expect(model.zoom["default"]?.count == 3)
    #expect(services.calls == ["origins default"])
  }

  @Test func notLoadedBeforePrepare() {
    let (_, store) = SettingsFixture.context()
    let model = PrivacyPaneModel(services: FakePrivacyServices(), diagnostics: nil, store: store)
    #expect(!model.isLoaded(SettingsPlace(pane: .privacy)))
  }

  @Test func categoryNeedsTheBlockerOn() {
    var state = ContentBlockerState(enabled: true, version: "", lists: [Self.list("a", .ads, enabled: true)], allowedHosts: [])
    #expect(PrivacyPaneModel.categoryOn(state, .ads))
    #expect(!PrivacyPaneModel.categoryOn(state, .trackers))
    state.enabled = false
    #expect(!PrivacyPaneModel.categoryOn(state, .ads))
  }

  @Test func turningOnUsesDefaultListsFirst() {
    let state = ContentBlockerState(enabled: false, version: "", lists: [
      Self.list("adguard-cookies", .cookies),
      Self.list("fanboy-cookie", .cookies),
      Self.list("cookie-default", .cookies, defaultOn: true),
    ], allowedHosts: [])
    let changes = PrivacyPaneModel.categoryChanges(state, .cookies, on: true)
    #expect(changes.lists == ["cookie-default"])
    #expect(changes.blockerEnabled == true)
  }

  @Test func turningOnFallsBackToEasyListOrFanboyThenEveryList() {
    let named = ContentBlockerState(enabled: true, version: "", lists: [
      Self.list("adguard-cookies", .cookies),
      Self.list("fanboy-cookiemonster", .cookies),
      Self.list("ads", .ads, enabled: true),
    ], allowedHosts: [])
    let fromNames = PrivacyPaneModel.categoryChanges(named, .cookies, on: true)
    #expect(fromNames.lists == ["fanboy-cookiemonster"])
    #expect(fromNames.blockerEnabled == nil)

    let unnamed = ContentBlockerState(enabled: true, version: "", lists: [
      Self.list("one", .cookies),
      Self.list("two", .cookies),
      Self.list("ads", .ads, enabled: true),
    ], allowedHosts: [])
    #expect(PrivacyPaneModel.categoryChanges(unnamed, .cookies, on: true).lists == ["one", "two"])
  }

  @Test func turningOffDisablesOnlyEnabledListsAndTheBlockerWhenNothingIsLeft() {
    let state = ContentBlockerState(enabled: true, version: "", lists: [
      Self.list("easylist", .ads, enabled: true, defaultOn: true),
      Self.list("extra", .ads),
      Self.list("easyprivacy", .trackers, defaultOn: true),
    ], allowedHosts: [])
    let changes = PrivacyPaneModel.categoryChanges(state, .ads, on: false)
    #expect(changes.lists == ["easylist"])
    #expect(changes.blockerEnabled == false)
  }

  @Test func listsWithoutAToggleKeepTheBlockerOn() {
    let state = ContentBlockerState(enabled: true, version: "", lists: [
      Self.list("easylist", .ads, enabled: true),
      Self.list("urlhaus", .security, enabled: true),
    ], allowedHosts: [])
    #expect(PrivacyPaneModel.categoryChanges(state, .ads, on: false).blockerEnabled == nil)
  }

  @Test func turningAdsOffAsksFirst() async {
    let (model, services, _, _) = await Self.make()
    model.requestCategory(.ads, on: false)
    #expect(model.confirmingAdsOff)
    #expect(services.calls.filter { $0.hasPrefix("list") }.isEmpty)
    await model.setCategory(.ads, on: false)
    #expect(services.calls.contains("list easylist false"))
    #expect(services.calls.contains("list ublock-filters false"))
    #expect(!services.calls.contains("list adguard-ads false"))
    #expect(!model.categoryOn(.ads))
    #expect(model.categoryOn(.trackers))
  }

  @Test func otherCategoriesDoNotAsk() async {
    let (model, services, _, _) = await Self.make()
    await model.setCategory(.cookies, on: true)
    #expect(!model.confirmingAdsOff)
    #expect(services.calls.contains("list fanboy-cookiemonster true"))
    #expect(model.categoryOn(.cookies))
  }

  @Test func aFailedListStillReloads() async {
    let (model, services, _, _) = await Self.make()
    services.failListCalls = true
    services.blocker?.version = "reloaded"
    await model.setCategory(.trackers, on: false)
    #expect(model.blocker?.version == "reloaded")
  }

  @Test func checkingAListTurnsTheBlockerBackOn() async {
    let (model, services, _, _) = await Self.make()
    services.blocker?.enabled = false
    await model.reloadBlocker()
    let list = try! #require(model.blocker?.lists.first { $0.id == "easylist-germany" })
    await model.setList(list, on: true)
    #expect(services.calls == ["origins default", "list easylist-germany true", "enabled true"])
    #expect(model.blocker?.enabled == true)
  }

  @Test func uncheckingAListLeavesTheBlockerAlone() async {
    let (model, services, _, _) = await Self.make()
    let list = try! #require(model.blocker?.lists.first { $0.id == "easylist" })
    await model.setList(list, on: false)
    #expect(!services.calls.contains { $0.hasPrefix("enabled") })
  }

  @Test func blockAgainRemovesTheHost() async {
    let (model, services, _, _) = await Self.make()
    await model.blockAgain("example.org")
    #expect(services.calls.last == "allowed example.org false")
    #expect(model.blocker?.allowedHosts == ["news.ycombinator.com"])
  }

  @Test func blockerChangesReload() async throws {
    let (model, services, _, _) = await Self.make()
    let watching = Task { for await _ in services.contentBlockerChanges() { await model.reloadBlocker() } }
    defer { watching.cancel() }
    try await Task.sleep(for: .milliseconds(20))
    services.blocker?.allowedHosts = []
    services.emitChange()
    try await Task.sleep(for: .milliseconds(50))
    #expect(model.blocker?.allowedHosts.isEmpty == true)
  }

  @Test func eachSectionKeepsItsOwnProfile() async {
    let (model, _, _, _) = await Self.make()
    model.sitePermissionsProfileId = "work"
    #expect(model.sitePermissionsProfile == "work")
    #expect(model.appLinksProfile == "default")
    #expect(model.zoomProfile == "default")
  }

  @Test func sitesOpenForTheChosenProfileAndChangesReloadTheList() async throws {
    let (model, services, _, _) = await Self.make()
    model.sitePermissionsProfileId = "work"
    model.openSite("https://github.com")
    guard case .site(let site) = try #require(model.sheet) else { Issue.record("no site sheet"); return }
    #expect(site.profile == "work")
    await site.load()
    services.origins["work"] = ["https://github.com"]
    await site.set(.camera, .block)
    #expect(services.calls.contains("site work https://github.com camera block"))
    #expect(model.origins["work"] == ["https://github.com"])
    #expect(site.settings?[.camera] == SiteSettingState(value: .block, isDefault: false))
  }

  @Test func siteRowsFollowTheListedOrderAndSkipUnlisted() async {
    let (_, services, _, _) = await Self.make()
    let site = PrivacySiteModel(services: services, profile: "default", origin: "https://meet.google.com") {}
    #expect(site.rows.isEmpty)
    await site.load()
    #expect(site.rows.map(\.type) == [.popups, .camera, .microphone, .location, .notifications, .javascript, .fileSystem])
    #expect(site.rows.map(\.label).first == "Pop-ups and redirects")
  }

  @Test func siteValueShowsDefaultWithItsEffectiveValue() {
    let inherited = SiteSettingState(value: .block, isDefault: true)
    #expect(PrivacySiteModel.shownValue(inherited) == .default)
    #expect(PrivacySiteModel.defaultNote(inherited) == "Default (block)")
    let set = SiteSettingState(value: .allow, isDefault: false)
    #expect(PrivacySiteModel.shownValue(set) == .allow)
    #expect(PrivacySiteModel.defaultNote(set) == nil)
  }

  @Test func resetAndClearSiteData() async {
    var reloads = 0
    let services = FakePrivacyServices()
    let site = PrivacySiteModel(services: services, profile: "default", origin: "https://github.com") { reloads += 1 }
    await site.reset()
    #expect(services.calls == ["reset default https://github.com"])
    #expect(reloads == 1)
    #expect(site.rows.isEmpty)
    await site.clearData()
    #expect(site.status == "Cleared 3 cookies and site data.")
    #expect(PrivacySiteModel.clearedText(ClearSiteDataResult(cookies: 1, storage: true)) == "Cleared 1 cookie and site data.")
    #expect(PrivacySiteModel.clearedText(ClearSiteDataResult(cookies: nil, storage: false)) == "Site data cleared.")
  }

  @Test func removingAnAppLinkReloads() async {
    let (model, services, _, _) = await Self.make()
    let zoomApp = try! #require(model.appLinks["default"]?.first)
    await model.removeAppLink(zoomApp)
    #expect(services.calls.last == "removeApp default https://zoom.us zoommtg")
    #expect(model.appLinks["default"]?.map(\.scheme) == ["spotify"])
  }

  @Test func resettingZoomSetsOneAndReloads() async {
    let (model, services, _, _) = await Self.make()
    await model.resetZoom("github.com")
    #expect(services.calls.last == "zoom default github.com 1.0")
    #expect(model.zoom["default"]?["github.com"] == nil)
  }

  @Test func derivedText() {
    #expect(PrivacyPaneModel.withoutScheme("https://meet.google.com") == "meet.google.com")
    #expect(PrivacyPaneModel.withoutScheme("http://localhost:3000") == "localhost:3000")
    #expect(PrivacyPaneModel.filtersText(1) == "1 filter")
    #expect(PrivacyPaneModel.filtersText(71_204) == "\(71_204.formatted()) filters")
    #expect(PrivacyPaneModel.listDescription(Self.list("x", .ads, defaultOn: true)) == "10 filters · On by default")
    #expect(PrivacyPaneModel.zoomText(1.1) == "110%")
    #expect(PrivacyPaneModel.zoomText(0.333) == "33%")
    let blocker = ContentBlockerState(enabled: true, version: "", lists: [], allowedHosts: [], networkFilters: 5, cosmeticFilters: nil)
    #expect(PrivacyPaneModel.rulesLoaded(blocker) == "5 network and 0 cosmetic rules loaded.")
    #expect(PrivacyPaneModel.appLinkDescription(ExternalAppAllowance(origin: "https://zoom.us", scheme: "zoommtg", app: "zoom.us", icon: nil)) == "Opens zoommtg: links in zoom.us")
    #expect(PrivacyPaneModel.appLinkDescription(ExternalAppAllowance(origin: "https://a.b", scheme: "x", app: nil, icon: nil)) == "Opens x: links in an app that's no longer installed")
  }

  @Test func imageHelpers() {
    #expect(PrivacyImages.hostInitial("https://www.github.com/x") == "G")
    #expect(PrivacyImages.hostInitial("http://127.0.0.1:8080") == "")
    #expect(PrivacyImages.hostInitial("about:blank") == "")
    let png = NSImage(size: NSSize(width: 2, height: 2), flipped: false) { _ in true }
    let data = try! #require(png.tiffRepresentation.flatMap { NSBitmapImageRep(data: $0)?.representation(using: .png, properties: [:]) })
    #expect(PrivacyImages.dataURI("data:image/png;base64,\(data.base64EncodedString())") != nil)
    #expect(PrivacyImages.dataURI(nil) == nil)
    #expect(PrivacyImages.dataURI("https://x") == nil)
  }

  @Test func diagnosticsSectionNeedsTelemetry() async {
    let (absent, _, _, _) = await Self.make(diagnostics: nil)
    #expect(!absent.diagnosticsAvailable)
    absent.setSharing(true)
    let off = FakeDiagnostics()
    off.available = false
    let (unavailable, _, _, _) = await Self.make(diagnostics: off)
    #expect(!unavailable.diagnosticsAvailable)
  }

  @Test func sharingToggleGoesThroughTheService() async {
    let diagnostics = FakeDiagnostics()
    let (model, _, _, _) = await Self.make(diagnostics: diagnostics)
    #expect(model.diagnosticsAvailable)
    #expect(!model.sharing)
    model.setSharing(true)
    #expect(diagnostics.sharing)
    #expect(diagnostics.sources == ["settings"])
    #expect(model.sharing)
  }

  @Test func diagnosticsCopyUsesTheAppAndHosts() {
    let copy = DiagnosticsCopy(appName: "Solara", services: FakeDiagnostics())
    #expect(copy.dailyCountShort.hasPrefix("Either way, Solara sends"))
    #expect(copy.footnote.hasPrefix("Sent to telemetry.solara.example with"))
    #expect(copy.updateChecks.hasPrefix("updates.solara.example counts"))
    #expect(copy.switchFileNote.contains("reads updates.solara.example/switches.json:"))
    #expect(copy.groups.map(\.title) == ["With everything", "Crashes and errors", "Usage", "Speed", "Even with sharing off", "Never"])
    #expect(copy.groups[4].items == [copy.dailyCount, copy.updateChecks, copy.switchFileNote])
    #expect(copy.sheetSubtitle == "Only while “Share anonymous crash reports and usage stats” is on, except what’s under “Even with sharing off”.")
  }

  @Test(.enabled(if: Snapshot.directory != nil))
  func rendersPrivacy() async throws {
    let (_, _, context, _) = await Self.make()
    try await Snapshot.renderPanes(context, [.privacy])
  }

  @Test(.enabled(if: Snapshot.directory != nil))
  func rendersPrivacyEmpty() async throws {
    let (context, store) = SettingsFixture.context()
    store.profiles = [store.profiles[0]]
    let services = FakePrivacyServices()
    services.origins = [:]
    services.allowances = [:]
    services.zoom = [:]
    services.blocker?.allowedHosts = []
    let model = PrivacyPaneModel(services: services, diagnostics: nil, store: store)
    context.panes[.privacy] = model
    await model.prepare(SettingsPlace(pane: .privacy))
    try await Snapshot.renderPanes(context, [.privacy], named: { _ in "privacy-empty" })
  }

  @Test(.enabled(if: Snapshot.directory != nil))
  func rendersPrivacySheets() async throws {
    let directory = try #require(Snapshot.directory)
    let (model, services, context, _) = await Self.make()
    let site = PrivacySiteModel(services: services, profile: "default", origin: "https://meet.google.com") {}
    await site.load()
    await site.clearData()
    let copy = DiagnosticsCopy(appName: context.appName, services: model.diagnostics)
    for dark in [false, true] {
      let scheme = dark ? "dark" : "light"
      try await Snapshot.render(FilterListsSheet(model: model).environment(\.settingsContext, context), size: NSSize(width: 500, height: 560), dark: dark, to: directory.appendingPathComponent("privacy-filterLists-\(scheme).png"))
      try await Snapshot.render(SiteSheet(model: site, favicons: model).environment(\.settingsContext, context), size: NSSize(width: 460, height: 520), dark: dark, to: directory.appendingPathComponent("privacy-site-\(scheme).png"))
      try await Snapshot.render(WhatsSentSheet(copy: copy) {}.environment(\.settingsContext, context), size: NSSize(width: 500, height: 580), dark: dark, to: directory.appendingPathComponent("privacy-whatsSent-\(scheme).png"))
    }
  }
}
