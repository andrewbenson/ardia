import Foundation

public let defaultSearchTemplate = "https://www.google.com/search?q="

struct ParsedUrl {
  var scheme: Units
  var host: Units
  var port: Units
  var path: Units
  var query: Units
  var hash: Units
}

private func isAuthorityEnd(_ c: UInt16) -> Bool { c == Unit.slash || c == Unit.question || c == Unit.hash }

func parseUrl(_ url: Units) -> ParsedUrl? {
  let t = JS.trim(url)
  guard let first = t.first, Unit.isAlpha(first) else { return nil }
  var i = 1
  while i < t.count && Unit.isSchemeTail(t[i]) { i += 1 }
  guard t.hasPrefix(Units("://"), at: i) else { return nil }
  let scheme = Array(t[..<i]).map(Unit.asciiLower)
  var at = i + 3
  var j = at
  while j < t.count && t[j] != Unit.at && !isAuthorityEnd(t[j]) { j += 1 }
  if j < t.count && t[j] == Unit.at { at = j + 1 }

  func tail(_ from: Int, host: Units) -> ParsedUrl? {
    var k = from
    var port = Units()
    if k < t.count && t[k] == Unit.colon {
      var d = k + 1
      while d < t.count && Unit.isDigit(t[d]) { d += 1 }
      if d > k + 1 {
        port = Array(t[(k + 1)..<d])
        k = d
      }
    }
    var e = k
    while e < t.count && t[e] != Unit.question && t[e] != Unit.hash { e += 1 }
    let path = Array(t[k..<e])
    var query = Units()
    if e < t.count && t[e] == Unit.question {
      var f = e
      while f < t.count && t[f] != Unit.hash { f += 1 }
      query = Array(t[e..<f])
      e = f
    }
    var hash = Units()
    if e < t.count {
      hash = Array(t[e...])
      if hash.contains(where: Unit.isLineTerminator) { return nil }
    }
    return ParsedUrl(scheme: scheme, host: JS.lower(host), port: port, path: path, query: query, hash: hash)
  }

  if at < t.count && t[at] == Unit.openBracket, let close = t[(at + 1)...].firstIndex(of: Unit.closeBracket) {
    if let parsed = tail(close + 1, host: Array(t[at...close])) { return parsed }
  }
  var h = at
  while h < t.count && t[h] != Unit.colon && !isAuthorityEnd(t[h]) { h += 1 }
  return tail(h, host: Array(t[at..<h]))
}

private let wwwDot = Units("www.")

func hostOf(_ url: Units) -> Units {
  let host = parseUrl(url)?.host ?? []
  return host.hasPrefix(wwwDot) ? Array(host[4...]) : host
}

public func hostOf(_ url: String) -> String { hostOf(url.units).string }

private let knownSchemes: Set<Units> = Set([
  "http", "https", "file", "about", "data", "blob", "mailto", "tel", "sms", "facetime", "ftp", "view-source",
  "solara", "chrome", "chrome-extension", "devtools", "x-apple.systempreferences", "itms-apps", "slack", "zoommtg", "vscode",
  "cursor", "notion", "figma", "spotify", "linear", "obsidian", "raycast",
].map(Units.init))

private let knownTlds: Set<Units> = Set((
  "com net org edu gov mil int info biz name pro mobi app dev io ai co me tv cc gg sh fm ly so to xyz online site tech store " +
    "blog shop cloud page news live art design studio agency media digital network systems solutions services software " +
    "email chat social link click space website world today life fun games game zone wiki tools codes run build host " +
    "rocks ninja guru expert academy school university health care money finance bank capital fund law legal travel " +
    "photos photo pics gallery video music film movie radio audio events social group team community church city " +
    "london nyc paris berlin tokyo africa asia eu aero coop museum jobs cat post tel travel moe onl one top vip win " +
    "work works company business center global plus inc ltd llc gmbh srl cafe restaurant pizza bar pub coffee wine beer " +
    "fashion style shoes clothing jewelry watch camera computer phone mobile download security domains hosting " +
    "google youtube gmail android chrome amazon apple microsoft windows office azure aws netflix meta search " +
    "local localhost test internal lan arpa onion " +
    "ac ad ae af ag ai al am ao aq ar as at au aw ax az ba bb bd be bf bg bh bi bj bm bn bo br bs bt bw by bz ca cc " +
    "cd cf cg ch ci ck cl cm cn co cr cu cv cw cx cy cz de dj dk dm do dz ec ee eg er es et eu fi fj fk fm fo fr ga " +
    "gd ge gf gg gh gi gl gm gn gp gq gr gs gt gu gw gy hk hm hn hr ht hu id ie il im in io iq ir is it je jm jo jp " +
    "ke kg kh ki km kn kp kr kw ky kz la lb lc li lk lr ls lt lu lv ly ma mc md me mg mh mk ml mm mn mo mp mq mr ms " +
    "mt mu mv mw mx my mz na nc ne nf ng ni nl no np nr nu nz om pa pe pf pg ph pk pl pm pn pr ps pt pw py qa re ro " +
    "rs ru rw sa sb sc sd se sg sh si sk sl sm sn so sr ss st su sv sx sy sz tc td tf tg th tj tk tl tm tn to tr tt " +
    "tv tw tz ua ug uk us uy uz va vc ve vg vi vn vu wf ws ye yt za zm zw"
).split(separator: " ").map { Units(String($0)) })

private let registries: Set<Units> = Set(JS.splitSpaces(Units(pslTlds)))

private func knownTld(_ tld: Units) -> Bool { knownTlds.contains(tld) || registries.contains(tld) }

private let localSuffixes = ["local", "localhost", "test", "internal", "lan", "home.arpa"].map { Units("." + $0) }

private func isDottedQuad(_ host: Units) -> Bool {
  let parts = host.split(separator: Unit.dot, omittingEmptySubsequences: false)
  return parts.count == 4 && parts.allSatisfy { (1...3).contains($0.count) && $0.allSatisfy(Unit.isDigit) }
}

private func isLocalHost(_ host: Units) -> Bool {
  host == Units("localhost") || !host.contains(Unit.dot) || host.first == Unit.openBracket || isDottedQuad(host)
    || localSuffixes.contains(where: host.hasSuffix)
}

private let label = "[a-zA-Z0-9\\u00a1-\\U0010ffff](?:[a-zA-Z0-9\\u00a1-\\U0010ffff-]*[a-zA-Z0-9\\u00a1-\\U0010ffff])?"
private let hostPattern = Pattern(
  "^([lL][oO][cC][aA][lL][hH][oO][sS][tT]|\\[[0-9a-fA-F:.]+\\]|([0-9]{1,3}\\.){3}[0-9]{1,3}|(\(label)\\.)+([a-zA-Z\\u00a1-\\U0010ffff](?:[a-zA-Z0-9\\u00a1-\\U0010ffff-]*[a-zA-Z0-9\\u00a1-\\U0010ffff])?|[xX][nN]--[a-zA-Z0-9-]+)|\(label))\\.?(:[0-9]{1,5})?(?=[/?#]|\\z)"
)

private let directSchemes = ["about", "data", "mailto", "tel", "sms", "facetime", "view-source"]

private func leadingScheme(_ input: Units) -> Units? {
  guard let first = input.first, Unit.isAlpha(first) else { return nil }
  var i = 1
  while i < input.count && Unit.isSchemeTail(input[i]) { i += 1 }
  guard i < input.count, input[i] == Unit.colon else { return nil }
  return Array(input[..<i])
}

private func encodeSpaces(_ s: Units) -> Units { s.replacingAll(JS.isSpace, with: Units("%20")) }

private func fixup(_ raw: Units) -> Units? {
  let input = JS.trim(raw)
  if input.isEmpty { return nil }
  if JS.hasSpace(input) {
    let schemeSlashes = leadingScheme(input).map { input.hasPrefix(Units("//"), at: $0.count + 1) } ?? false
    let absolutePath = input.count > 1 && input[0] == Unit.slash && !JS.isSpace(input[1]) && input[1] != Unit.slash
    if !schemeSlashes && !absolutePath { return nil }
  }
  for scheme in directSchemes where input.asciiCaseInsensitivePrefix(scheme + ":") { return input }

  let scheme = leadingScheme(input).map { $0.map(Unit.asciiLower) }
  let known = scheme.map { knownSchemes.contains($0) || isAppScheme($0.string) } ?? false
  if let scheme {
    let after = Array(input[(scheme.count + 1)...])
    if known && (after.hasPrefix(Units("//")) || !(after.first.map(Unit.isDigit) ?? false)) {
      return scheme + encodeSpaces(Array(input[scheme.count...]))
    }
    if !known && after.hasPrefix(Units("//")) { return input }
  }
  if input.first == Unit.slash && !input.hasPrefix(Units("//")) { return Units("file://") + encodeSpaces(input) }

  let urlish: Set<UInt16> = [Unit.dot, Unit.colon, Unit.slash, Unit.question, Unit.hash, Unit.openBracket]
  if !input.contains(where: urlish.contains) {
    return JS.lower(input) == Units("localhost") ? Units("http://") + input : nil
  }
  guard let host = hostPattern.firstMatch(input) else { return nil }
  var name = JS.lower(host[1]!)
  if name.last == Unit.dot { name.removeLast() }
  let numeric = !name.isEmpty && name.allSatisfy { Unit.isDigit($0) || $0 == Unit.dot }
  if numeric && !name.contains(Unit.dot) { return nil }
  let dotted = name.contains(Unit.dot) && !numeric && name.first != Unit.openBracket
  let tld = dotted ? Array(name[(name.lastIndex(of: Unit.dot)! + 1)...]) : []
  let rest = Array(input[host.end...])
  let special = name == Units("localhost") || name.first == Unit.openBracket || numeric
  let proto = Units(isLocalHost(name) ? "http://" : "https://")
  if special || (dotted && (knownTld(tld) || tld.hasPrefix(Units("xn--")))) { return proto + input }
  let hasPort = host[5] != nil
  if !hasPort && !rest.contains(Unit.slash) && !rest.contains(Unit.question) && !rest.contains(Unit.hash) { return nil }
  let pathEnd = rest.firstIndex { $0 == Unit.question || $0 == Unit.hash } ?? rest.count
  let path = Array(rest[..<pathEnd])
  var query = Units()
  if let q = rest.firstIndex(of: Unit.question) {
    let end = rest[q...].firstIndex(of: Unit.hash) ?? rest.count
    query = Array(rest[q..<end])
  }
  let fragment = rest.firstIndex(of: Unit.hash).map { Array(rest[$0...]) } ?? []
  let parts = (hasPort ? 1 : 0) + (path.isEmpty ? 0 : 1) + (query.count > 1 ? 1 : 0) + (fragment.count > 1 ? 1 : 0)
  return hasPort || path.last == Unit.slash || parts > 1 ? proto + input : nil
}

func isJavaScriptUrl(_ url: Units) -> Bool {
  var start = 0
  while start < url.count && url[start] <= Unit.space { start += 1 }
  let stripped = url[start...].filter { $0 != 0x09 && $0 != Unit.newline && $0 != Unit.carriageReturn }
  let afterViewSource = stripped.asciiCaseInsensitivePrefix("view-source:") ? 12 : 0
  return stripped.asciiCaseInsensitivePrefix("javascript:", at: afterViewSource)
}

func withoutJavaScriptScheme(_ text: Units) -> Units {
  var out = text
  while true {
    var start = 0
    while start < out.count && (out[start] <= Unit.space || out[start] == 0x7f) { start += 1 }
    guard out.asciiCaseInsensitivePrefix("javascript:", at: start) else { return out }
    out = Array(out[(start + 11)...])
  }
}

func fixupUrl(_ raw: Units) -> Units? {
  guard let url = fixup(raw), !isJavaScriptUrl(url) else { return nil }
  return toAppUrl(url)
}

public func fixupUrl(_ raw: String) -> String? { fixupUrl(raw.units)?.string }

func searchUrlFor(_ template: Units, _ query: Units) -> Units {
  let q = Units(JS.encodeURIComponent(JS.trim(query).string))
  let placeholder = Units("%s")
  guard template.contains(placeholder) else { return template + q }
  var out = Units()
  var i = 0
  while i < template.count {
    if template.hasPrefix(placeholder, at: i) {
      out += q
      i += 2
    } else {
      out.append(template[i])
      i += 1
    }
  }
  return out
}

public func searchUrlFor(_ template: String, _ query: String) -> String { searchUrlFor(template.units, query.units).string }

public func resolveInput(_ raw: String, search: String = defaultSearchTemplate) -> String {
  let input = JS.trim(raw.units)
  if input.isEmpty { return "" }
  if input.first == Unit.question {
    return input.count > 1 ? searchUrlFor(search.units, Array(input[1...])).string : ""
  }
  return (fixupUrl(input) ?? searchUrlFor(search.units, input)).string
}

public enum PasteAction: Sendable, Equatable {
  case go(url: String)
  case search(query: String)
}

public func classifyPaste(_ text: String) -> PasteAction? {
  let trimmed = JS.trim(withoutJavaScriptScheme(JS.trim(text.units)))
  if trimmed.isEmpty { return nil }
  let url = JS.hasSpace(trimmed) ? nil : fixupUrl(trimmed)
  if let url, !url.asciiCaseInsensitivePrefix("about:"), !url.asciiCaseInsensitivePrefix("data:") {
    return .go(url: cleanUrl(url.string))
  }
  return .search(query: JS.collapseSpaces(trimmed).slice(0, 2000).string)
}

public func sanitizePaste(_ text: String) -> String {
  if text.isEmpty { return "" }
  let trimmed = JS.trim(text.units)
  var parts: [Units] = []
  var i = 0
  while i < trimmed.count {
    let start = i
    while i < trimmed.count && !JS.isSpace(trimmed[i]) { i += 1 }
    parts.append(Array(trimmed[start..<i]))
    if i == trimmed.count { break }
    let spaceStart = i
    while i < trimmed.count && JS.isSpace(trimmed[i]) { i += 1 }
    parts.append(Array(trimmed[spaceStart..<i]))
  }
  if parts.isEmpty { parts = [[]] }
  if parts.count == 1 && parts[0].isEmpty { return " " }
  let breaksLine = { (part: Units) in part.contains(Unit.newline) || part.contains(Unit.carriageReturn) }
  let spaced = parts.indices.contains { $0 % 2 == 1 && !breaksLine(parts[$0]) }
  var out = Units()
  for (i, part) in parts.enumerated() {
    if i % 2 == 0 || !breaksLine(part) { out += part } else if spaced { out.append(Unit.space) }
  }
  return JS.trimStart(withoutJavaScriptScheme(out)).string
}

public struct Breadcrumb: Sendable, Equatable {
  public var host: String
  public var trail: [String]

  public init(host: String, trail: [String]) {
    self.host = host
    self.trail = trail
  }
}

private let defaultPorts: [Units: Units] = [
  Units("http"): Units("80"), Units("https"): Units("443"), Units("ws"): Units("80"), Units("wss"): Units("443"), Units("ftp"): Units("21"),
]

private let crumbSeparators: Set<UInt16> = [0x7c, 0x2f, 0xb7, 0x2013, 0x2014, 0x2d]

private func splitCrumbs(_ title: Units) -> [Units] {
  var out: [Units] = []
  var start = 0
  var i = 0
  while i < title.count {
    if JS.isSpace(title[i]) && i + 2 < title.count && crumbSeparators.contains(title[i + 1]) && JS.isSpace(title[i + 2]) {
      out.append(Array(title[start..<i]))
      i += 3
      start = i
    } else {
      i += 1
    }
  }
  out.append(Array(title[start...]))
  return out
}

public func breadcrumb(_ url: String, title: String? = nil) -> Breadcrumb {
  let u = url.units
  let parsed = parseUrl(u)
  let app = appUrlOrigin(u)
  let host: Units
  if let app {
    host = app
  } else if let parsed {
    let shown = displayHost(parsed.host)
    let port = !parsed.port.isEmpty && parsed.port != defaultPorts[parsed.scheme] ? [Unit.colon] + parsed.port : []
    host = (shown.hasPrefix(wwwDot) ? Array(shown[4...]) : shown) + port
  } else {
    host = u
  }
  var seen: Set<Units> = [JS.lower(host)]
  if app != nil, let parsed { seen.insert(parsed.host) }
  var trail: [String] = []
  for piece in splitCrumbs((title ?? "").units) {
    let s = JS.trim(piece)
    let key = JS.lower(s)
    if s.isEmpty || seen.contains(key) { continue }
    seen.insert(key)
    trail.append(s.string)
  }
  return Breadcrumb(host: host.string, trail: trail)
}

func urlForDisplay(_ url: Units) -> Units {
  if appUrlOrigin(url) != nil {
    let app = toAppUrl(url)
    guard let firstSlash = app.firstIndex(of: Unit.slash), app.hasPrefix([Unit.slash, Unit.slash], at: firstSlash) else { return app }
    var hostEnd = firstSlash + 2
    while hostEnd < app.count, !isAuthorityEnd(app[hostEnd]) { hostEnd += 1 }
    guard hostEnd < app.count, app[hostEnd] == Unit.slash else { return app }
    let after = hostEnd + 1
    if after == app.count || app[after] == Unit.question || app[after] == Unit.hash {
      return Array(app[..<hostEnd]) + Array(app[after...])
    }
    return app
  }
  var rest = url
  if let scheme = leadingScheme(url), url.hasPrefix(Units("//"), at: scheme.count + 1) {
    rest = Array(url[(scheme.count + 3)...])
    var end = 0
    while end < rest.count, !isAuthorityEnd(rest[end]) { end += 1 }
    if let at = rest[..<end].lastIndex(of: Unit.at) { rest = Array(rest[(at + 1)...]) }
  }
  var hostEnd = 0
  while hostEnd < rest.count, !isAuthorityEnd(rest[hostEnd]), rest[hostEnd] != Unit.colon { hostEnd += 1 }
  let shown = displayHost(Array(rest[..<hostEnd])) + Array(rest[hostEnd...])
  return shown.asciiCaseInsensitivePrefix("www.") ? Array(shown[4...]) : shown
}

public func urlForDisplay(_ url: String) -> String { urlForDisplay(url.units).string }
