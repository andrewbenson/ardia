import Foundation

public struct SearchEngineExtension: Sendable, Equatable {
  public var id: String
  public var name: String

  public init(id: String, name: String) {
    self.id = id
    self.name = name
  }
}

public struct SearchEngine: Sendable, Equatable {
  public var id: String
  public var name: String
  public var keyword: String
  public var url: String
  public var suggestUrl: String?
  public var custom: Bool
  public var `extension`: SearchEngineExtension?

  public init(id: String, name: String, keyword: String, url: String, suggestUrl: String? = nil, custom: Bool = false, extension: SearchEngineExtension? = nil) {
    self.id = id
    self.name = name
    self.keyword = keyword
    self.url = url
    self.suggestUrl = suggestUrl
    self.custom = custom
    self.extension = `extension`
  }
}

public struct CustomSearchEngine: Sendable, Equatable {
  public var id: String
  public var name: String
  public var keyword: String
  public var url: String

  public init(id: String, name: String, keyword: String, url: String) {
    self.id = id
    self.name = name
    self.keyword = keyword
    self.url = url
  }
}

public struct ExtensionSearchEngine: Sendable, Equatable {
  public var profile: String
  public var extensionId: String
  public var extensionName: String
  public var name: String
  public var keyword: String
  public var url: String
  public var suggestUrl: String?
  public var isDefault: Bool

  public init(profile: String, extensionId: String, extensionName: String, name: String, keyword: String, url: String, suggestUrl: String?, isDefault: Bool) {
    self.profile = profile
    self.extensionId = extensionId
    self.extensionName = extensionName
    self.name = name
    self.keyword = keyword
    self.url = url
    self.suggestUrl = suggestUrl
    self.isDefault = isDefault
  }
}

public let builtInEngines: [SearchEngine] = [
  SearchEngine(
    id: "google", name: "Google", keyword: "google.com", url: "https://www.google.com/search?q=%s",
    suggestUrl: "https://suggestqueries.google.com/complete/search?client=firefox&ie=utf-8&oe=utf-8&q=%s"
  ),
  SearchEngine(id: "bing", name: "Bing", keyword: "bing.com", url: "https://www.bing.com/search?q=%s", suggestUrl: "https://api.bing.com/osjson.aspx?query=%s"),
  SearchEngine(
    id: "duckduckgo", name: "DuckDuckGo", keyword: "duckduckgo.com", url: "https://duckduckgo.com/?q=%s",
    suggestUrl: "https://duckduckgo.com/ac/?q=%s&type=list"
  ),
  SearchEngine(id: "perplexity", name: "Perplexity", keyword: "perplexity.ai", url: "https://www.perplexity.ai/search?q=%s"),
  SearchEngine(id: "chatgpt", name: "ChatGPT", keyword: "chatgpt.com", url: "https://chatgpt.com/?q=%s"),
  SearchEngine(
    id: "ecosia", name: "Ecosia", keyword: "ecosia.org", url: "https://www.ecosia.org/search?q=%s",
    suggestUrl: "https://ac.ecosia.org/autocomplete?q=%s&type=list"
  ),
  SearchEngine(
    id: "brave", name: "Brave Search", keyword: "search.brave.com", url: "https://search.brave.com/search?q=%s",
    suggestUrl: "https://search.brave.com/api/suggest?q=%s"
  ),
  SearchEngine(id: "kagi", name: "Kagi", keyword: "kagi.com", url: "https://kagi.com/search?q=%s"),
  SearchEngine(
    id: "startpage", name: "Startpage", keyword: "startpage.com", url: "https://www.startpage.com/do/search?q=%s",
    suggestUrl: "https://www.startpage.com/osuggestions?q=%s"
  ),
  SearchEngine(
    id: "yahoo", name: "Yahoo", keyword: "yahoo.com", url: "https://search.yahoo.com/search?p=%s",
    suggestUrl: "https://search.yahoo.com/sugg/ff?output=fxjson&command=%s"
  ),
  SearchEngine(
    id: "baidu", name: "Baidu", keyword: "baidu.com", url: "https://www.baidu.com/s?wd=%s",
    suggestUrl: "https://www.baidu.com/su?action=opensearch&ie=utf-8&wd=%s"
  ),
  SearchEngine(
    id: "yandex", name: "Yandex", keyword: "yandex.com", url: "https://yandex.com/search/?text=%s",
    suggestUrl: "https://suggest.yandex.com/suggest-ff.cgi?part=%s"
  ),
]

public func allEngines(custom: [CustomSearchEngine] = [], extension: [ExtensionSearchEngine] = []) -> [SearchEngine] {
  var engines = builtInEngines + custom.map { SearchEngine(id: $0.id, name: $0.name, keyword: $0.keyword, url: $0.url, custom: true) }
  var seen = Set<Units>()
  for e in `extension` {
    let key = e.extensionId.units
    if seen.contains(key) { continue }
    seen.insert(key)
    engines.append(
      SearchEngine(
        id: extensionEngineId(e.extensionId), name: e.name, keyword: e.keyword, url: e.url,
        suggestUrl: e.suggestUrl?.isEmpty == false ? e.suggestUrl : nil,
        extension: SearchEngineExtension(id: e.extensionId, name: e.extensionName)
      )
    )
  }
  return engines
}

public func extensionEngineId(_ extensionId: String) -> String { "extension:\(extensionId)" }

public func controllingExtensionEngine(_ engines: [ExtensionSearchEngine]) -> ExtensionSearchEngine? {
  engines.first { $0.isDefault }
}

private func withoutPlaceholders(_ url: String) -> String {
  let u = url.units
  var out = Units()
  var i = 0
  while i < u.count {
    if u[i] == 0x7b, let close = u[(i + 1)...].firstIndex(where: { $0 == 0x7d || $0 == 0x7b || $0 == Unit.percent }), u[close] == 0x7d {
      i = close + 1
    } else {
      out.append(u[i])
      i += 1
    }
  }
  return out.string
}

public func extensionEnginesFromChrome(profile: String, list: ParsedJSON?) -> [ExtensionSearchEngine] {
  var groups: [ParsedJSON] = []
  switch list {
  case .object(let pairs)?: groups = pairs.map(\.value)
  case .array(let items)?: groups = items
  default: break
  }
  var out: [ExtensionSearchEngine] = []
  for group in groups {
    guard case .array(let entries) = group else { continue }
    for e in entries {
      guard e.isObject, let ext = e["extension"], case .string(let extId)? = ext["id"] else { continue }
      if e["isOmniboxExtension"]?.truthy == true { continue }
      guard case .string(let url)? = e["url"], url.units.contains(Units("%s")) else { continue }
      if out.contains(where: { $0.extensionId.sameUnits(extId) }) { continue }
      let extName = ext["name"]
      let name: String
      if case .string(let n)? = e["name"], !n.isEmpty {
        name = n
      } else if let extName, extName != .null {
        name = extName.jsString
      } else {
        name = ""
      }
      var suggestUrl: String?
      if case .string(let s)? = e["suggestionsUrl"], s.units.contains(Units("%s")) { suggestUrl = withoutPlaceholders(s) }
      out.append(
        ExtensionSearchEngine(
          profile: profile,
          extensionId: extId,
          extensionName: extName?.string ?? "",
          name: name,
          keyword: e["keyword"]?.string ?? "",
          url: withoutPlaceholders(url),
          suggestUrl: suggestUrl,
          isDefault: e["default"] == .bool(true)
        )
      )
    }
  }
  return out
}

public func engineById(_ engines: [SearchEngine], _ id: String?) -> SearchEngine {
  engines.first { id != nil && $0.id.sameUnits(id!) } ?? builtInEngines[0]
}

public func searchUrl(_ engine: SearchEngine, _ query: String) -> String { searchUrlFor(engine.url, query) }

func searchUrl(_ template: Units, _ query: Units) -> Units { searchUrlFor(template, query) }

public func suggestRequestUrl(_ engine: SearchEngine, _ query: String) -> String? {
  guard let suggest = engine.suggestUrl, !suggest.isEmpty, !JS.trim(query.units).isEmpty else { return nil }
  return searchUrlFor(suggest, query)
}

public func engineHost(_ engine: SearchEngine) -> String { engineHost(engine.url.units).string }

func engineHost(_ url: Units) -> Units {
  var replaced = Units()
  var i = 0
  while i < url.count {
    if url.hasPrefix(Units("%s"), at: i) {
      replaced.append(0x71)
      i += 2
    } else {
      replaced.append(url[i])
      i += 1
    }
  }
  return hostOf(replaced)
}

public func parseSuggestions(_ body: ParsedJSON?) -> [String] {
  guard case .array(let outer)? = body, outer.count > 1, case .array(let items) = outer[1] else { return [] }
  return items.compactMap { item in
    guard case .string(let s) = item else { return nil }
    let trimmed = JS.trim(s.units)
    return trimmed.isEmpty ? nil : trimmed.string
  }
}

public struct EngineInput: Sendable, Equatable {
  public var name: String
  public var keyword: String
  public var url: String

  public init(name: String, keyword: String, url: String) {
    self.name = name
    self.keyword = keyword
    self.url = url
  }
}

public func validateEngine(_ input: EngineInput, _ engines: [SearchEngine], ignoreId: String? = nil) -> String? {
  let name = JS.trim(input.name.units)
  let keyword = JS.lower(JS.trim(input.keyword.units))
  let url = JS.trim(input.url.units)
  if name.isEmpty { return "Enter a name." }
  if keyword.isEmpty { return "Enter a shortcut." }
  if JS.hasSpace(keyword) { return "The shortcut can't contain spaces." }
  if !startsWithWebOrigin(url) { return "Enter a URL that starts with http:// or https://." }
  if !url.contains(Units("%s")) { return "The URL must contain %s where the search terms go." }
  if engines.contains(where: { !(ignoreId.map($0.id.sameUnits) ?? false) && JS.lower($0.keyword.units) == keyword }) {
    return "“\(keyword.string)” is already used by another search engine."
  }
  return nil
}

private func startsWithWebOrigin(_ url: Units) -> Bool {
  let at: Int
  if url.asciiCaseInsensitivePrefix("https://") {
    at = 8
  } else if url.asciiCaseInsensitivePrefix("http://") {
    at = 7
  } else {
    return false
  }
  return at < url.count && url[at] != Unit.slash && url[at] != Unit.question && url[at] != Unit.hash && !JS.isSpace(url[at])
}

public func makeCustomEngine(_ input: EngineInput, id: String) -> CustomSearchEngine {
  CustomSearchEngine(id: id, name: JS.trim(input.name), keyword: JS.lower(JS.trim(input.keyword.units)).string, url: JS.trim(input.url))
}
