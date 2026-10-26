import Foundation

public enum ExtensionOpen: String, Sendable, Equatable {
  case action, options
}

public enum Suggestion: Sendable, Equatable {
  case page(url: String, title: String, favicon: String?, tabId: String? = nil, bookmarked: Bool = false, visited: Bool = false)
  case search(query: String, url: String, engine: String, suggested: Bool = false, bang: Bool = false)
  case calc(expression: String, value: String, url: String)
  case action(id: String, title: String, icon: String? = nil, hint: String? = nil)
  case create(id: String, title: String, url: String, site: String)
  case `extension`(id: String, title: String, icon: String?, open: ExtensionOpen)

  public var kind: String {
    switch self {
    case .page: "page"
    case .search: "search"
    case .calc: "calc"
    case .action: "action"
    case .create: "create"
    case .extension: "extension"
    }
  }
}

func pageKey(_ url: Units) -> Units {
  var end = url.firstIndex(of: Unit.hash) ?? url.count
  if end > 0 && url[end - 1] == Unit.slash { end -= 1 }
  return end == url.count ? url : Array(url[..<end])
}

func suggestionKeyUnits(_ s: Suggestion) -> Units {
  switch s {
  case .page(let url, _, _, let tabId, _, _):
    return Units(tabId?.isEmpty == false ? "tab:" : "page:") + pageKey(url.units)
  case .search(_, let url, _, _, _):
    return Units("search:") + url.units
  case .calc(let expression, _, _):
    return Units("calc:") + expression.units
  case .action(let id, _, _, _):
    return Units("action:") + id.units
  case .create(let id, _, _, _):
    return Units("create:") + id.units
  case .extension(let id, _, _, let open):
    return Units("extension:\(open.rawValue):") + id.units
  }
}

public func suggestionKey(_ s: Suggestion) -> String { suggestionKeyUnits(s).string }

public func displayUrl(_ url: String) -> String { displayUrl(url.units).string }

func displayUrl(_ url: Units) -> Units {
  var shown = urlForDisplay(url)
  if shown.last == Unit.slash { shown.removeLast() }
  return shown
}

public struct OpenTabRow: Sendable, Equatable {
  public var id: String
  public var url: String
  public var title: String
  public var favicon: String?
  public var lastActiveAt: Double

  public init(id: String, url: String, title: String, favicon: String?, lastActiveAt: Double) {
    self.id = id
    self.url = url
    self.title = title
    self.favicon = favicon
    self.lastActiveAt = lastActiveAt
  }
}

public func recentTabSuggestions(_ tabs: [OpenTabRow], exclude: String? = nil, limit: Int = 8) -> [Suggestion] {
  tabs.enumerated()
    .filter { !$0.element.url.isEmpty && !(exclude.map($0.element.id.sameUnits) ?? false) }
    .sorted { $0.element.lastActiveAt != $1.element.lastActiveAt ? $0.element.lastActiveAt > $1.element.lastActiveAt : $0.offset < $1.offset }
    .prefix(max(limit, 0))
    .map { .page(url: $0.element.url, title: $0.element.title, favicon: $0.element.favicon, tabId: $0.element.id) }
}

public struct ExtensionCandidate: ActionCandidate, Equatable {
  public var id: String
  public var title: String
  public var icon: String?
  public var action: Bool
  public var options: Bool
  public var keywords: [String]? { nil }

  public init(id: String, title: String, icon: String?, action: Bool, options: Bool) {
    self.id = id
    self.title = title
    self.icon = icon
    self.action = action
    self.options = options
  }
}

public struct ExtensionRows: Sendable, Equatable {
  public var rows: [Suggestion]
  public var exact: Bool
}

public func extensionSuggestions(_ query: String, _ extensions: [ExtensionCandidate], limit: Int = 2) -> ExtensionRows {
  if extensions.isEmpty { return ExtensionRows(rows: [], exact: false) }
  let q = JS.trim(query.units)
  let matches = matchActions(q.string, extensions, limit: limit).filter { $0.exact || (q.count >= 3 && $0.score >= 50) }
  if matches.isEmpty { return ExtensionRows(rows: [], exact: false) }
  var rows: [Suggestion] = []
  for (i, m) in matches.enumerated() {
    let x = m.action
    if x.action { rows.append(.extension(id: x.id, title: x.title, icon: x.icon, open: .action)) }
    if x.options && (i == 0 || !x.action) { rows.append(.extension(id: x.id, title: x.title, icon: x.icon, open: .options)) }
  }
  return rows.isEmpty ? ExtensionRows(rows: [], exact: false) : ExtensionRows(rows: rows, exact: matches[0].exact)
}

public struct QuickCreate: Sendable, Equatable {
  public var id: String
  public var title: String
  public var url: String
  public var aliases: [String]
  public var site: String
}

public let quickCreates: [QuickCreate] = [
  QuickCreate(id: "doc", title: "New Google Doc", url: "https://docs.new", aliases: ["doc", "docs", "document", "google doc", "gdoc"], site: "docs.google.com"),
  QuickCreate(id: "sheet", title: "New Google Sheet", url: "https://sheets.new", aliases: ["sheet", "sheets", "spreadsheet", "google sheet"], site: "sheets.google.com"),
  QuickCreate(id: "slides", title: "New Google Slides", url: "https://slides.new", aliases: ["slides", "slide", "presentation", "deck", "google slides"], site: "slides.google.com"),
  QuickCreate(id: "form", title: "New Google Form", url: "https://forms.new", aliases: ["form", "forms", "survey", "google form"], site: "forms.google.com"),
  QuickCreate(id: "meeting", title: "New Google Calendar Event", url: "https://meeting.new", aliases: ["meeting", "event", "calendar", "invite"], site: "calendar.google.com"),
  QuickCreate(id: "meet", title: "New Google Meet", url: "https://meet.new", aliases: ["meet", "call", "video call", "google meet"], site: "meet.google.com"),
  QuickCreate(id: "notion", title: "New Notion Page", url: "https://notion.new", aliases: ["notion", "note", "page", "notion page"], site: "notion.so"),
  QuickCreate(id: "linear", title: "New Linear Issue", url: "https://linear.new", aliases: ["linear", "issue", "ticket", "linear issue"], site: "linear.app"),
  QuickCreate(id: "jira", title: "New Jira Issue", url: "https://jira.new", aliases: ["jira", "ticket", "issue", "jira issue"], site: "atlassian.com"),
  QuickCreate(id: "confluence", title: "New Confluence Page", url: "https://confluence.new", aliases: ["wiki", "confluence", "confluence page"], site: "atlassian.com"),
  QuickCreate(id: "gist", title: "New GitHub Gist", url: "https://gist.new", aliases: ["gist", "snippet", "github gist"], site: "github.com"),
  QuickCreate(id: "repo", title: "New GitHub Repository", url: "https://repo.new", aliases: ["repo", "repository", "github repo"], site: "github.com"),
  QuickCreate(id: "figma", title: "New Figma Design", url: "https://figma.new", aliases: ["figma", "design", "figma design"], site: "figma.com"),
  QuickCreate(id: "figjam", title: "New FigJam Board", url: "https://figjam.new", aliases: ["figjam", "whiteboard", "board"], site: "figma.com"),
  QuickCreate(id: "word", title: "New Word Document", url: "https://word.new", aliases: ["word", "word document"], site: "word.cloud.microsoft"),
  QuickCreate(id: "excel", title: "New Excel Workbook", url: "https://excel.new", aliases: ["excel", "workbook"], site: "excel.cloud.microsoft"),
  QuickCreate(id: "powerpoint", title: "New PowerPoint Presentation", url: "https://powerpoint.new", aliases: ["powerpoint", "ppt"], site: "powerpoint.cloud.microsoft"),
]

private let quickCreateAliases: [[Units]] = quickCreates.map { $0.aliases.map(Units.init) }

public func matchQuickCreate(_ query: String, limit: Int = 3) -> [QuickCreate] {
  matchQuickCreate(query.units, limit: limit)
}

func matchQuickCreate(_ query: Units, limit: Int = 3) -> [QuickCreate] {
  let q = JS.trimStart(query)
  let wordEnd: Int
  if q.asciiCaseInsensitivePrefix("new") {
    wordEnd = 3
  } else if q.asciiCaseInsensitivePrefix("create") {
    wordEnd = 6
  } else {
    return []
  }
  guard wordEnd < q.count, JS.isSpace(q[wordEnd]) else { return [] }
  var restStart = wordEnd
  while restStart < q.count && JS.isSpace(q[restStart]) { restStart += 1 }
  let tail = q[restStart...]
  if tail.contains(where: Unit.isLineTerminator) { return [] }
  let rest = JS.collapseSpaces(JS.lower(JS.trim(Array(tail))))
  let n = max(limit, 0)
  if rest.isEmpty { return Array(quickCreates.prefix(n)) }
  var ranked: [(c: QuickCreate, r: Int, order: Int)] = []
  for (order, c) in quickCreates.enumerated() {
    let aliases = quickCreateAliases[order]
    let r = aliases.contains(rest) ? 0 : aliases.contains(where: { $0.hasPrefix(rest) }) ? 1 : -1
    if r >= 0 { ranked.append((c, r, order)) }
  }
  ranked.sort { $0.r != $1.r ? $0.r < $1.r : $0.order < $1.order }
  return ranked.prefix(n).map(\.c)
}
