import Foundation
import Synchronization
import Testing

@testable import SolaraOmnibox

private let now = 1_790_208_000_000.0
private let extensionNow = 1_792_800_000_000.0
private let day = 86_400_000.0
private let history = [
  HistoryRow(url: "https://x.com/home", title: "(1) Home / X", favicon: nil, visits: 40, lastVisit: now - 1000),
  HistoryRow(url: "https://x.com/notifications", title: "Notifications / X", favicon: nil, visits: 5, lastVisit: now - 5000),
  HistoryRow(url: "https://www.xing.com/", title: "XING", favicon: nil, visits: 1, lastVisit: now - day * 10),
  HistoryRow(url: "https://github.com/", title: "GitHub", favicon: nil, visits: 12, lastVisit: now - 2000),
]

private func rows(_ items: [Suggestion]) -> [String] {
  items.map { item in
    switch item {
    case .page(let url, _, _, let tabId, _, _): tabId != nil ? "tab:\(url)" : url
    case .search(let query, _, _, let suggested, _): "\(suggested ? "suggest" : "search"):\(query)"
    case .calc(_, let value, _): "calc:\(value)"
    case .action(let id, _, _, _): "action:\(id)"
    case .create(let id, _, _, _): "create:\(id)"
    case .extension(let id, _, _, let open): "extension:\(open.rawValue):\(id)"
    }
  }
}

private func build(_ text: String, tabs: [TabRow] = [], history: [HistoryRow] = history, bookmarks: [BookmarkRow] = [], _ options: SuggestOptions = SuggestOptions(now: now)) -> SuggestionResult {
  buildSuggestions(text, SuggestionSource(tabs: tabs, history: history, bookmarks: bookmarks), options)
}

@Suite struct SuggestTests {
  @Test func inlineCompletionNeverTakesALongQueryURL() {
    let signIn = "https://accounts.google.com/v3/signin/identifier?continue=https%3A%2F%2Fmail.google.com%2Fmail%2Fu%2F0%2F&service=mail&flowName=GlifWebSignIn&flowEntry=AccountChooser&ec=asw-gmail-globalnav-signin#inbox"
    let hist = [
      HistoryRow(url: "https://mail.google.com/mail/u/0/?service=mail&continue=" + JS.encodeURIComponent(signIn) + "#inbox", title: "Inbox - me@gmail.com - Gmail", favicon: "gmail.ico", visits: 50, lastVisit: now - 1000),
      HistoryRow(url: signIn, title: "Sign in - Google Accounts", favicon: nil, visits: 3, lastVisit: now - 2000),
    ]
    let m = build("m", history: hist)
    #expect(m.completion == "ail.google.com")
    #expect(m.items.first == .page(url: "https://mail.google.com/", title: "", favicon: "gmail.ico"))
    #expect(rows(m.items).contains(hist[0].url))
    #expect(build("a", history: hist).completion == "ccounts.google.com")
    #expect(build("mail.google.com/m", history: hist).completion == "")
    #expect(build("x.com/h").completion == "ome")
  }

  @Test func freeTextPutsASearchFirstAndNeverAutocompletes() {
    let r = build("git hub")
    #expect(r.completion == "")
    #expect(r.items.first?.kind == "search")
  }

  @Test func preventInlineAfterADeletion() {
    let typed = { (text: String, prevent: Bool) in build(text, SuggestOptions(now: now, preventInline: prevent)) }
    let before = typed("gi", false)
    #expect(before.completion == "thub.com")
    #expect(rows(before.items).first == "https://github.com/")
    let after = typed("gi", true)
    #expect(after.completion == "")
    #expect(rows(after.items).first == "search:gi")
    #expect(rows(after.items).contains("https://github.com/"))
    #expect(rows(typed("gith", true).items).first == "search:gith")
    #expect(rows(typed("x.c", true).items).first == "search:x.c")
    #expect(rows(typed("github.com", true).items).first == "https://github.com/")
    #expect(typed("github.com", true).completion == "")
    #expect(rows(typed("x.com/home", true).items).first == "https://x.com/home")
    #expect(rows(typed("https://x.com/notifications", true).items).first == "https://x.com/notifications")
    #expect(typed("git", false).completion == "hub.com")
  }

  @Test func fourLettersListUpToFourActionsAShorterWordTwo() {
    let actions = ActionIndex([
      CommandAction(id: "split:right", title: "Split View Side by Side"),
      CommandAction(id: "split:bottom", title: "Split View Stacked"),
      CommandAction(id: "split:withTab", title: "Split View with Tab"),
      CommandAction(id: "split:exit", title: "Exit Split View"),
      CommandAction(id: "split:flip", title: "Flip Split View"),
      CommandAction(id: "newTab", title: "New Tab"),
    ])
    let actionRows = { (q: String) in rows(build(q, SuggestOptions(now: now, actions: actions)).items).filter { $0.hasPrefix("action:") } }
    #expect(actionRows("split").sorted() == ["action:split:bottom", "action:split:exit", "action:split:right", "action:split:withTab"])
    #expect(actionRows("sp").count == 2)
    #expect(actionRows("exit split") == ["action:split:exit"])
    #expect(actionRows("github") == [])
  }

  @Test func preventInlineKeepsQuickCreateActionsAndCalculatorRules() {
    let actions = ActionIndex([CommandAction(id: "newTab", title: "New Tab")])
    #expect(rows(build("new tab", SuggestOptions(now: now, actions: actions, preventInline: true)).items).first == "action:newTab")
    #expect(rows(build("2+2", SuggestOptions(now: now, preventInline: true)).items).first == "search:2+2")
  }

  @Test func aWordAndASpaceDoesNotComplete() {
    #expect(build("git").completion == "hub.com")
    for text in ["git ", "git  ", "gi\t", "x "] {
      let r = build(text)
      #expect(r.completion == "", "\(text)")
      #expect(rows(r.items).first == "search:\(JS.trim(text))", "\(text)")
      #expect(rows(r.items).contains("https://github.com/") || text.hasPrefix("x"))
    }
    #expect(rows(build("github.com ").items).first == "https://github.com/")
    #expect(build("github.com ").completion == "")
    #expect(rows(build("x.com/home ").items).first == "https://x.com/home")
    #expect(build(" git").completion == "hub.com")
    #expect(build("git hub ").completion == "")
    #expect(rows(build("git s").items).first == "search:git s")
  }

  @Test func onlyAVisitedPageCompletes() {
    let bookmarks = [BookmarkRow(url: "https://bookmarked.example.org/", title: "Reading list", favicon: nil)]
    let tabs = [TabRow(id: "t9", url: "https://news.ycombinator.com/", title: "Hacker News", favicon: nil)]
    let r = build("bookm", tabs: tabs, bookmarks: bookmarks)
    #expect(r.completion == "")
    #expect(rows(r.items).contains("https://bookmarked.example.org/"))
    let t = build("news", tabs: tabs, bookmarks: bookmarks)
    #expect(t.completion == "")
    #expect(rows(t.items).contains("tab:https://news.ycombinator.com/"))
    let visited = history + [HistoryRow(url: "https://bookmarked.example.org/", title: "Reading list", favicon: nil, visits: 1, lastVisit: now - 9000)]
    #expect(build("bookm", history: visited, bookmarks: bookmarks).completion == "arked.example.org")
    let tabbed = history + [HistoryRow(url: "https://news.ycombinator.com/", title: "Hacker News", favicon: nil, visits: 2, lastVisit: now - 9000)]
    #expect(build("news", tabs: tabs, history: tabbed, bookmarks: bookmarks).completion == ".ycombinator.com")
    let deep = [BookmarkRow(url: "https://bookmarked.example.org/a/b", title: "Deep", favicon: nil)]
    let host = history + [HistoryRow(url: "https://bookmarked.example.org/", title: "Home", favicon: nil, visits: 3, lastVisit: now - 100)]
    #expect(build("bookm", history: host, bookmarks: deep).completion == "arked.example.org")
  }

  @Test func openTabsAreMarkedExceptTheBarsOwnTab() {
    let tabs = [TabRow(id: "t1", url: "https://github.com/pulls", title: "Pull requests", favicon: nil)]
    if case .page(_, _, _, let tabId, _, _)? = build("pull", tabs: tabs).items.first { #expect(tabId == "t1") } else { Issue.record("no page row") }
    let own = build("pull", tabs: tabs, SuggestOptions(now: now, currentTabId: "t1"))
    #expect(!own.items.contains { if case .page(_, _, _, let id, _, _) = $0 { id != nil } else { false } })
  }

  @Test func aTypedOrCompletedAddressOpensEvenWhenATabHasIt() {
    let tabs = [TabRow(id: "t1", url: "https://ugc.hekuto.dev/#grid", title: "UGC Radar", favicon: nil)]
    let hist = [HistoryRow(url: "https://ugc.hekuto.dev/#grid", title: "UGC Radar", favicon: nil, visits: 3, lastVisit: now - 1000)]
    for typed in ["ugc.hekuto.dev", "ugc.hek", "https://ugc.hekuto.dev/#grid"] {
      let r = rows(build(typed, tabs: tabs, history: hist).items)
      #expect(r.first?.hasPrefix("https://ugc.hekuto.dev/") == true, "\(typed): \(r.first ?? "")")
      #expect(r.contains("tab:https://ugc.hekuto.dev/#grid"), "\(typed)")
    }
  }

  @Test func frecencyFrequentAndRecentBeatsOld() {
    let hist = [
      HistoryRow(url: "https://a.com/docs", title: "Rust docs", favicon: nil, visits: 2, lastVisit: now - day * 60),
      HistoryRow(url: "https://b.com/docs", title: "Rust docs", favicon: nil, visits: 20, lastVisit: now - day),
    ]
    #expect(rows(build("docs rust", history: hist).items) == ["search:docs rust", "https://b.com/docs", "https://a.com/docs"])
  }

  @Test func anIndexAnswersKeystrokeAfterKeystrokeLikeAFreshOne() {
    let index = SuggestionIndex(history: history, bookmarks: [])
    for text in ["g", "gi", "git", "gith", "gi", "x", "x.", "x.c", "x.co", "x.com", "x.com/", "x.com/n", "no", "not", "notif"] {
      #expect(index.suggest(text, tabs: [], options: SuggestOptions(now: now)) == build(text), "\(text)")
    }
  }

  @Test func prepareWithADeadlineFinishesLater() {
    let many = (0..<5000).map { HistoryRow(url: "https://h\($0).example/page", title: "Page \($0)", favicon: nil, visits: 1, lastVisit: now) }
    let index = SuggestionIndex(history: many, bookmarks: [])
    _ = index.prepare(deadline: .now - .seconds(1))
    #expect(index.prepare())
    #expect(index.suggest("h42", tabs: [], options: SuggestOptions(now: now)) == build("h42", history: many))
  }
}

@Suite struct ExtensionRowTests {
  static let list = [
    ExtensionCandidate(id: "ublock", title: "uBlock Origin", icon: "data:image/png;base64,ublock", action: true, options: true),
    ExtensionCandidate(id: "onepassword", title: "1Password – Password Manager", icon: "data:image/png;base64,onepassword", action: true, options: false),
    ExtensionCandidate(id: "darkreader", title: "Dark Reader", icon: "data:image/png;base64,darkreader", action: true, options: true),
    ExtensionCandidate(id: "nopopup", title: "Video Speed Controller", icon: "data:image/png;base64,nopopup", action: false, options: true),
  ]

  func keys(_ rows: [Suggestion]) -> [String] {
    rows.map { if case .extension(let id, _, _, let open) = $0 { "\(open.rawValue):\(id)" } else { $0.kind } }
  }

  @Test func aTypedNameListsItWithItsOptionsUnderTheBestMatch() {
    let r = extensionSuggestions("ublock", Self.list)
    #expect(!r.exact)
    #expect(keys(r.rows) == ["action:ublock", "options:ublock"])
    #expect(r.rows.first == .extension(id: "ublock", title: "uBlock Origin", icon: "data:image/png;base64,ublock", open: .action))
  }

  @Test func aLaterWordFindsItAndNoOptionsPageMeansNoOptionsRow() {
    #expect(keys(extensionSuggestions("password", Self.list).rows) == ["action:onepassword"])
    #expect(keys(extensionSuggestions("reader", Self.list).rows) == ["action:darkreader", "options:darkreader"])
  }

  @Test func anExtensionWithoutAToolbarActionOffersItsOptionsOnly() {
    #expect(keys(extensionSuggestions("video speed", Self.list).rows) == ["options:nopopup"])
  }

  @Test func twoLettersListNothingUnlessTheyAreTheWholeName() {
    #expect(extensionSuggestions("ub", Self.list).rows.isEmpty)
    #expect(extensionSuggestions("zzq", Self.list).rows.isEmpty)
    #expect(extensionSuggestions("ublock", []).rows.isEmpty)
    let short = extensionSuggestions("ab", [ExtensionCandidate(id: "ab", title: "AB", icon: nil, action: true, options: true)])
    #expect(short.exact)
    #expect(keys(short.rows) == ["action:ab", "options:ab"])
  }

  @Test func inTheBarAPartialNameListsTheExtensionAfterTheSearchRow() {
    let r = build("dark rea", history: [], SuggestOptions(now: extensionNow, extensions: Self.list))
    #expect(keys(r.items) == ["search", "action:darkreader", "options:darkreader"])
  }

  @Test func theExactNameGoesFirstUnlessAVisitedSiteCompletesInline() {
    let exact = build("Dark Reader", history: [], SuggestOptions(now: extensionNow, extensions: Self.list))
    #expect(Array(keys(exact.items).prefix(2)) == ["action:darkreader", "search"])
    let hist = [HistoryRow(url: "https://ublock.example/", title: "uBlock site", favicon: nil, visits: 9, lastVisit: extensionNow - 1000)]
    let site = build("ublock", history: hist, SuggestOptions(now: extensionNow, extensions: [ExtensionCandidate(id: "ublock", title: "uBlock", icon: nil, action: true, options: true)]))
    #expect(site.completion == ".example")
    #expect(site.items.first?.kind == "page")
    #expect(keys(site.items).contains("action:ublock"))
  }

  @Test func withoutExtensionsTheBarIsUnchanged() {
    #expect(build("dark reader", history: []) == build("dark reader", history: [], SuggestOptions(now: extensionNow, extensions: [])))
  }
}

@Suite struct OpenTabTests {
  func tab(_ id: String, _ lastActiveAt: Double, _ url: String? = nil) -> OpenTabRow {
    OpenTabRow(id: id, url: url ?? "https://\(id).example/", title: id.uppercased(), favicon: nil, lastActiveAt: lastActiveAt)
  }

  func ids(_ rows: [Suggestion]) -> [String?] {
    rows.map { if case .page(_, _, _, let id, _, _) = $0 { id } else { nil } }
  }

  @Test func openTabsComeMostRecentlyUsedFirst() {
    let rows = recentTabSuggestions([tab("a", 1), tab("b", 3), tab("c", 2)])
    #expect(ids(rows) == ["b", "c", "a"])
    #expect(rows.first == .page(url: "https://b.example/", title: "B", favicon: nil, tabId: "b"))
  }

  @Test func theBarsTabAndTabsWithoutAPageAreLeftOut() {
    #expect(ids(recentTabSuggestions([tab("a", 5), tab("blank", 9, ""), tab("b", 4)], exclude: "a")) == ["b"])
  }

  @Test func theListStopsAtTheLimit() {
    let tabs = (0..<12).map { tab("t\($0)", Double($0)) }
    #expect(ids(recentTabSuggestions(tabs, limit: 3)) == ["t11", "t10", "t9"])
    #expect(recentTabSuggestions(tabs).count == 8)
  }

  @Test func tabsSharingAURLEachKeepTheirOwnRow() {
    #expect(recentTabSuggestions([tab("a", 1, "https://same.example/"), tab("b", 2, "https://same.example/")]).count == 2)
  }
}

private let sources = ScopeSources(engines: builtInEngines)

private func bar(_ typed: String, _ completion: String = "", _ scope: SearchScope? = nil, _ scopeFrom: String = "") -> SiteSearchKeyState {
  SiteSearchKeyState(typed: typed, completion: completion, scope: scope, offered: scope != nil ? nil : offeredSiteSearch(typed, completion, sources), scopeFrom: scopeFrom)
}

@Suite struct SiteSearchTests {
  @Test func tabEntersSiteSearchWhileInlineCompletionIsShowing() {
    let state = bar("google", ".com")
    #expect(state.offered?.name == "Google")
    #expect(siteSearchKey("Tab", SiteSearchKeyModifiers(), state) == .enter(scope: state.offered!, from: "google.com"))
  }

  @Test func tabEntersSiteSearchFromAShortPrefix() {
    guard case .enter(let scope, let from)? = siteSearchKey("Tab", SiteSearchKeyModifiers(), bar("goo", "gle.com")) else { Issue.record("no enter"); return }
    #expect(scope.name == "Google")
    #expect(from == "google.com")
  }

  @Test func tabEntersSiteSearchForATypedSite() {
    guard case .enter(let scope, let from)? = siteSearchKey("Tab", SiteSearchKeyModifiers(), bar("x.com")) else { Issue.record("no enter"); return }
    #expect(scope.kind == .site && scope.name == "X" && from == "x.com")
  }

  @Test func tabAcceptsTheCompletionWhenNoSiteSearchIsOffered() {
    let state = bar("exampl", "e.org")
    #expect(state.offered == nil)
    #expect(siteSearchKey("Tab", SiteSearchKeyModifiers(), state) == .accept(text: "example.org"))
  }

  @Test func tabWithNothingToEnterOrAcceptIsLeftToTheCaller() {
    #expect(siteSearchKey("Tab", SiteSearchKeyModifiers(), bar("hello world")) == nil)
    #expect(siteSearchKey("Tab", SiteSearchKeyModifiers(), bar("")) == nil)
  }

  @Test func shiftTabNeverEntersSiteSearch() {
    #expect(siteSearchKey("Tab", SiteSearchKeyModifiers(shiftKey: true), bar("google", ".com")) == nil)
  }

  @Test func tabInsideSiteSearchDoesNotEnterItAgain() {
    let google = bar("google", ".com").offered!
    #expect(siteSearchKey("Tab", SiteSearchKeyModifiers(), bar("", "", google, "google.com")) == nil)
  }

  @Test func backspaceInAnEmptySiteSearchLeavesIt() {
    let x = bar("x.com").offered!
    #expect(siteSearchKey("Backspace", SiteSearchKeyModifiers(), bar("", "", x, "x.com")) == .leave(text: "x.com"))
  }

  @Test func siteSearchEnteredByASpaceLeavesWithTheSpace() {
    let entry = keywordBySpace("x.com", "x.com ")
    #expect(entry == KeywordBySpace(keyword: "x.com", from: "x.com "))
    let x = bar("x.com").offered!
    #expect(siteSearchKey("Backspace", SiteSearchKeyModifiers(), bar("", "", x, entry!.from)) == .leave(text: "x.com "))
  }

  @Test func aSpaceAfterTheRestoredTextIsAPlainSpace() {
    #expect(keywordBySpace("x.com ", "x.com  ") == nil)
  }

  @Test func onlyASpaceAtTheEndEntersSiteSearchByKeyword() {
    #expect(keywordBySpace("x.com", "x.coma") == nil)
    #expect(keywordBySpace("x.com", " x.com") == nil)
    #expect(keywordBySpace("", " ") == nil)
  }

  @Test func siteSearchAsksForBackspaceTheWholeTimeItIsOn() {
    #expect(asksForBackspace(bar("x.com").offered))
    #expect(!asksForBackspace(nil))
  }

  @Test func aForwardedBackspaceLeavesEvenWhileTextRemains() {
    let x = bar("x.com").offered!
    #expect(siteSearchKey("Backspace", SiteSearchKeyModifiers(), bar("a", "", x, "x.com")) == .leave(text: "x.com"))
  }

  @Test func backspaceWithAModifierNeverLeavesSiteSearch() {
    let state = bar("", "", bar("x.com").offered!, "x.com")
    for mods in [SiteSearchKeyModifiers(altKey: true), SiteSearchKeyModifiers(metaKey: true), SiteSearchKeyModifiers(shiftKey: true), SiteSearchKeyModifiers(ctrlKey: true)] {
      #expect(siteSearchKey("Backspace", mods, state) == nil)
    }
  }

  @Test func backspaceOutsideSiteSearchIsAPlainDelete() {
    #expect(siteSearchKey("Backspace", SiteSearchKeyModifiers(), bar("x.co")) == nil)
    #expect(siteSearchKey("Backspace", SiteSearchKeyModifiers(), bar("")) == nil)
  }

  @Test func ctrlTabIsLeftToTheTabSwitcher() {
    #expect(siteSearchKey("Tab", SiteSearchKeyModifiers(ctrlKey: true), bar("google", ".com")) == nil)
  }

  @Test func noSiteSearchIsOfferedForTextWithSpaces() {
    #expect(offeredSiteSearch("google maps", "", sources) == nil)
    #expect(offeredSiteSearch("  ", ".com", sources) == nil)
  }
}

private final class FakeFetch: Sendable {
  let calls = Mutex<[String]>([])

  func fetch(_ url: String) async throws -> FetchResponse {
    calls.withLock { $0.append(url) }
    try await Task.sleep(for: .milliseconds(30))
    let query = JS.decodeURIComponent(String(url.split(separator: "q=").last ?? "")) ?? ""
    return FetchResponse(ok: true, body: Data("[\"\(query)\", [\"a\", \"b\"]]".utf8))
  }
}

private func waitUntil(_ condition: () -> Bool) async throws {
  let deadline = ContinuousClock.now + .seconds(30)
  while !condition() && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
}

@Suite struct SuggestFetcherTests {
  @Test func aNewerRequestAbortsTheOneInFlightWhichNeverAnswers() async throws {
    let fake = FakeFetch()
    let fetcher = SuggestFetcher(fetch: { try await fake.fetch($0) }, delay: .milliseconds(10))
    let results = Mutex<[String]>([])
    let google = engineById(builtInEngines, "google")
    fetcher.request(google, "old") { _ in results.withLock { $0.append("old") } }
    try await waitUntil { fake.calls.withLock { $0.count } == 1 }
    #expect(fake.calls.withLock { $0.count } == 1)
    fetcher.request(google, "new") { _ in results.withLock { $0.append("new") } }
    try await waitUntil { !results.withLock { $0.isEmpty } }
    try await Task.sleep(for: .milliseconds(100))
    #expect(results.withLock { $0 } == ["new"])
  }

  @Test func aCachedAnswerComesBackWithoutAFetch() async throws {
    let fake = FakeFetch()
    let fetcher = SuggestFetcher(fetch: { try await fake.fetch($0) }, delay: .milliseconds(1))
    let google = engineById(builtInEngines, "google")
    let got = Mutex<[[String]]>([])
    fetcher.request(google, "react") { s in got.withLock { $0.append(s) } }
    try await waitUntil { got.withLock { $0.count } == 1 }
    fetcher.request(google, "react") { s in got.withLock { $0.append(s) } }
    try await waitUntil { got.withLock { $0.count } == 2 }
    #expect(fake.calls.withLock { $0.count } == 1)
    #expect(got.withLock { $0 } == [["a", "b"], ["a", "b"]])
  }

  @Test func anEngineWithoutSuggestionsOrAnEmptyQueryNeverFetches() async throws {
    let fake = FakeFetch()
    let fetcher = SuggestFetcher(fetch: { try await fake.fetch($0) }, delay: .milliseconds(1))
    fetcher.request(engineById(builtInEngines, "kagi"), "react") { _ in Issue.record("answered") }
    fetcher.request(engineById(builtInEngines, "google"), "   ") { _ in Issue.record("answered") }
    try await Task.sleep(for: .milliseconds(50))
    #expect(fake.calls.withLock { $0.isEmpty })
  }
}
