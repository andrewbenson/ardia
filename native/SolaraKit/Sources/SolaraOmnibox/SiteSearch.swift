import Foundation

public struct SiteSearch: Sendable, Equatable {
  public var host: String
  public var name: String
  public var url: String

  public init(host: String, name: String, url: String) {
    self.host = host
    self.name = name
    self.url = url
  }
}

public let popularSiteSearches: [SiteSearch] = [
  SiteSearch(host: "youtube.com", name: "YouTube", url: "https://www.youtube.com/results?search_query=%s"),
  SiteSearch(host: "wikipedia.org", name: "Wikipedia", url: "https://en.wikipedia.org/w/index.php?search=%s"),
  SiteSearch(host: "github.com", name: "GitHub", url: "https://github.com/search?q=%s"),
  SiteSearch(host: "amazon.com", name: "Amazon", url: "https://www.amazon.com/s?k=%s"),
  SiteSearch(host: "reddit.com", name: "Reddit", url: "https://www.reddit.com/search/?q=%s"),
  SiteSearch(host: "x.com", name: "X", url: "https://x.com/search?q=%s"),
  SiteSearch(host: "twitter.com", name: "X", url: "https://x.com/search?q=%s"),
  SiteSearch(host: "stackoverflow.com", name: "Stack Overflow", url: "https://stackoverflow.com/search?q=%s"),
  SiteSearch(host: "npmjs.com", name: "npm", url: "https://www.npmjs.com/search?q=%s"),
  SiteSearch(host: "maps.google.com", name: "Google Maps", url: "https://www.google.com/maps/search/%s"),
  SiteSearch(host: "drive.google.com", name: "Google Drive", url: "https://drive.google.com/drive/search?q=%s"),
  SiteSearch(host: "mail.google.com", name: "Gmail", url: "https://mail.google.com/mail/u/0/#search/%s"),
  SiteSearch(host: "imdb.com", name: "IMDb", url: "https://www.imdb.com/find/?q=%s"),
  SiteSearch(host: "open.spotify.com", name: "Spotify", url: "https://open.spotify.com/search/%s"),
  SiteSearch(host: "linkedin.com", name: "LinkedIn", url: "https://www.linkedin.com/search/results/all/?keywords=%s"),
  SiteSearch(host: "ebay.com", name: "eBay", url: "https://www.ebay.com/sch/i.html?_nkw=%s"),
  SiteSearch(host: "pinterest.com", name: "Pinterest", url: "https://www.pinterest.com/search/pins/?q=%s"),
  SiteSearch(host: "news.ycombinator.com", name: "Hacker News", url: "https://hn.algolia.com/?q=%s"),
  SiteSearch(host: "developer.mozilla.org", name: "MDN", url: "https://developer.mozilla.org/en-US/search?q=%s"),
  SiteSearch(host: "figma.com", name: "Figma", url: "https://www.figma.com/files/search?q=%s"),
  SiteSearch(host: "notion.so", name: "Notion", url: "https://www.notion.so/search?q=%s"),
  SiteSearch(host: "apps.apple.com", name: "App Store", url: "https://www.apple.com/us/search/%s?src=serp"),
  SiteSearch(host: "translate.google.com", name: "Google Translate", url: "https://translate.google.com/?text=%s"),
]

public enum SearchScopeKind: String, Sendable, Equatable {
  case engine, site, history
}

public struct SearchScope: Sendable, Equatable {
  public var kind: SearchScopeKind
  public var name: String
  public var host: String
  public var url: String
  public var engineId: String?

  public init(kind: SearchScopeKind, name: String, host: String, url: String, engineId: String? = nil) {
    self.kind = kind
    self.name = name
    self.host = host
    self.url = url
    self.engineId = engineId
  }
}

public struct ScopeSources: Sendable {
  public let engines: [SearchEngine]
  public let sites: [SiteSearch]
  let hostSet: Set<Units>
  let engineHosts: [Units]
  let engineKeywords: [Units]
  let siteHosts: [(host: Units, label: Units?)]

  public init(engines: [SearchEngine], sites: [SiteSearch] = popularSiteSearches, hosts: [String] = []) {
    self.engines = engines
    self.sites = sites
    hostSet = Set(hosts.map(\.units))
    engineHosts = engines.map { engineHost($0.url.units) }
    engineKeywords = engines.map { JS.lower($0.keyword.units) }
    siteHosts = sites.map { site in
      let host = site.host.units
      let twoLabels = host.split(separator: Unit.dot, omittingEmptySubsequences: false).count == 2
      return (host, twoLabels ? siteLabel(host) : nil)
    }
  }
}

private func normalize(_ text: Units) -> Units {
  var t = JS.lower(JS.trim(text))
  var letters = 0
  while letters < t.count && Unit.isLowerAlpha(t[letters]) { letters += 1 }
  if letters > 0 && t.hasPrefix(Units("://"), at: letters) { t.removeFirst(letters + 3) }
  if t.hasPrefix(Units("www.")) { t.removeFirst(4) }
  if t.last == Unit.slash { t.removeLast() }
  return t
}

private func siteLabel(_ host: Units) -> Units {
  let parts = host.split(separator: Unit.dot, omittingEmptySubsequences: false)
  return parts.count >= 2 ? Array(parts[parts.count - 2]) : host
}

private func engineScope(_ e: SearchEngine) -> SearchScope {
  SearchScope(kind: .engine, name: e.name, host: engineHost(e), url: e.url, engineId: e.id)
}

public func findScope(_ text: String, _ sources: ScopeSources) -> SearchScope? {
  let t = normalize(text.units)
  if t.isEmpty || JS.hasSpace(t) { return nil }
  let parsedHost = hostOf(Units("https://") + t)
  let host = parsedHost.isEmpty ? t : parsedHost
  for (i, e) in sources.engines.enumerated() where e.custom && sources.engineKeywords[i] == t { return engineScope(e) }
  for (i, e) in sources.engines.enumerated() where !e.custom {
    let eHost = sources.engineHosts[i]
    if sources.engineKeywords[i] == host || eHost == host || (t.count >= 3 && t == siteLabel(eHost)) { return engineScope(e) }
  }
  for (i, s) in sources.sites.enumerated() {
    let (siteHost, label) = sources.siteHosts[i]
    if siteHost == host || host.hasSuffix([Unit.dot] + siteHost) || (t == host && t.count >= 3 && label == t) {
      return SearchScope(kind: .site, name: s.name, host: s.host, url: s.url)
    }
  }
  if host.contains(Unit.dot) && sources.hostSet.contains(host) {
    let name = host.string
    return SearchScope(kind: .history, name: name, host: name, url: "")
  }
  return nil
}

public func scopedSearchUrl(_ scope: SearchScope, _ query: String, _ defaultEngine: SearchEngine) -> String {
  scopedSearchUrl(scope, query.units, defaultEngine.url.units).string
}

func scopedSearchUrl(_ scope: SearchScope, _ query: Units, _ defaultTemplate: Units) -> Units {
  if scope.kind == .history { return searchUrlFor(defaultTemplate, Units("site:\(scope.host) ") + JS.trim(query)) }
  return searchUrlFor(scope.url.units, query)
}

public func offeredSiteSearch(_ typed: String, _ completion: String, _ sources: ScopeSources) -> SearchScope? {
  let t = JS.trim(typed.units)
  if t.isEmpty || JS.hasSpace(t) { return nil }
  return findScope(typed + completion, sources)
}

public struct SiteSearchKeyState: Sendable, Equatable {
  public var typed: String
  public var completion: String
  public var scope: SearchScope?
  public var offered: SearchScope?
  public var scopeFrom: String

  public init(typed: String, completion: String, scope: SearchScope?, offered: SearchScope?, scopeFrom: String) {
    self.typed = typed
    self.completion = completion
    self.scope = scope
    self.offered = offered
    self.scopeFrom = scopeFrom
  }
}

public struct SiteSearchKeyModifiers: Sendable, Equatable {
  public var shiftKey = false
  public var altKey = false
  public var metaKey = false
  public var ctrlKey = false

  public init(shiftKey: Bool = false, altKey: Bool = false, metaKey: Bool = false, ctrlKey: Bool = false) {
    self.shiftKey = shiftKey
    self.altKey = altKey
    self.metaKey = metaKey
    self.ctrlKey = ctrlKey
  }
}

public enum SiteSearchKey: Sendable, Equatable {
  case enter(scope: SearchScope, from: String)
  case leave(text: String)
  case accept(text: String)
}

public struct KeywordBySpace: Sendable, Equatable {
  public var keyword: String
  public var from: String
}

public func keywordBySpace(_ typed: String, _ next: String) -> KeywordBySpace? {
  let t = typed.units
  if JS.trim(t).isEmpty || (t.last.map(JS.isSpace) ?? false) || next.units != t + [Unit.space] { return nil }
  return KeywordBySpace(keyword: typed, from: next)
}

public func asksForBackspace(_ scope: SearchScope?) -> Bool { scope != nil }

public func siteSearchKey(_ key: String, _ modifiers: SiteSearchKeyModifiers, _ state: SiteSearchKeyState) -> SiteSearchKey? {
  if key == "Tab" && !modifiers.shiftKey && !modifiers.ctrlKey {
    if state.scope == nil, let offered = state.offered { return .enter(scope: offered, from: state.typed + state.completion) }
    if !state.completion.isEmpty { return .accept(text: state.typed + state.completion) }
    return nil
  }
  let plain = !modifiers.shiftKey && !modifiers.altKey && !modifiers.metaKey && !modifiers.ctrlKey
  if key == "Backspace" && plain && state.scope != nil { return .leave(text: state.scopeFrom) }
  return nil
}
