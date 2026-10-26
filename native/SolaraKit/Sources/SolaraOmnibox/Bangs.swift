import Foundation
import Synchronization

public struct Bang: Sendable, Equatable {
  public var trigger: String
  public var name: String
  public var template: String
  public var home: String

  public init(trigger: String, name: String, template: String, home: String) {
    self.trigger = trigger
    self.name = name
    self.template = template
    self.home = home
  }
}

public protocol BangTable: Sendable {
  var size: Int { get }
  func get(_ trigger: String) -> Bang?
}

public struct BangMatch: Sendable, Equatable {
  public var bang: Bang
  public var query: String
  public var url: String
}

public let bangPlaceholder = "{searchTerms}"
private let storedPlaceholder = "{s}"
private let minBangs = 1000
public let maxBangListChars = 4_000_000
private let requiredTriggers = ["gh", "w", "yt"]
private let bangDocumentMagic = "ardia-bangs 1"

private func endOfString(_ text: Units, _ from: Int) -> Int {
  var at = from
  while true {
    guard let quote = text[min(at, text.count)...].firstIndex(of: Unit.quote) else { return text.count }
    var slashes = 0
    while quote - 1 - slashes >= 0 && text[quote - 1 - slashes] == Unit.backslash { slashes += 1 }
    if slashes % 2 == 0 { return quote + 1 }
    at = quote + 1
  }
}

private func skipBlank(_ text: Units, _ from: Int) -> Int {
  var at = from
  while true {
    while at < text.count && JS.isSpace(text[at]) { at += 1 }
    if text.hasPrefix(Units("//"), at: at) {
      at = text.index(of: [Unit.newline], from: at) ?? text.count
    } else if text.hasPrefix(Units("/*"), at: at) {
      at = text.index(of: Units("*/"), from: at + 2).map { $0 + 2 } ?? text.count
    } else {
      return at
    }
  }
}

func stripLooseJson(_ text: Units) -> Units {
  var parts: [ArraySlice<UInt16>] = []
  var from = 0
  var pos = 0
  while pos < text.count {
    guard let at = text[pos...].firstIndex(where: { $0 == Unit.quote || $0 == Unit.slash || $0 == Unit.comma }) else { break }
    let c = text[at]
    if c == Unit.quote {
      pos = endOfString(text, at + 1)
    } else if c == Unit.slash {
      let next: UInt16? = at + 1 < text.count ? text[at + 1] : nil
      if next != Unit.slash && next != 0x2a {
        pos = at + 1
        continue
      }
      parts.append(text[from..<at])
      if next == Unit.slash {
        from = text.index(of: [Unit.newline], from: at) ?? text.count
      } else {
        from = text.index(of: Units("*/"), from: at + 2).map { $0 + 2 } ?? text.count
      }
      pos = from
    } else {
      let blank = skipBlank(text, at + 1)
      let close: UInt16? = blank < text.count ? text[blank] : nil
      if close == Unit.closeBracket || close == 0x7d {
        parts.append(text[from..<at])
        from = at + 1
      }
      pos = at + 1
    }
  }
  parts.append(text[min(from, text.count)...])
  return Array(parts.joined())
}

public func parseLooseJson(_ text: String) throws -> ParsedJSON {
  var parser = JSONParser(stripLooseJson(text.units))
  return try parser.parseDocument()
}

public func isValidBangTemplate(_ template: String) -> Bool { isValidBangTemplate(template.units) }

func isValidBangTemplate(_ t: Units) -> Bool {
  var i: Int
  if t.asciiCaseInsensitivePrefix("https://") {
    i = 8
  } else if t.asciiCaseInsensitivePrefix("http://") {
    i = 7
  } else {
    return false
  }
  let hostStart = i
  while i < t.count && (Unit.isAlnum(t[i]) || t[i] == Unit.dot || t[i] == Unit.dash) { i += 1 }
  if i == hostStart { return false }
  if i < t.count && t[i] == Unit.colon {
    var d = i + 1
    while d < t.count && Unit.isDigit(t[d]) { d += 1 }
    if d > i + 1 { i = d }
  }
  if i == t.count { return true }
  guard t[i] == Unit.slash || t[i] == Unit.question || t[i] == Unit.hash else { return false }
  return !t[(i + 1)...].contains(where: JS.isSpace)
}

private func origin(_ s: Units) -> (scheme: Units, host: Units)? {
  guard let first = s.first, Unit.isAlpha(first) else { return nil }
  var i = 1
  while i < s.count && Unit.isSchemeTail(s[i]) { i += 1 }
  guard s.hasPrefix(Units("://"), at: i) else { return nil }
  var end = i + 3
  while end < s.count && s[end] != Unit.slash && s[end] != Unit.question && s[end] != Unit.hash && s[end] != Unit.backslash { end += 1 }
  return (Array(s[..<i]), Array(s[(i + 3)..<end]))
}

public func staysOnSite(_ url: String, _ template: String) -> Bool {
  let u = url.units
  guard let to = origin(u), let from = origin(template.units), !from.host.isEmpty else { return false }
  if u.contains(where: { JS.isSpace($0) || $0 <= 0x1f || $0 == 0x7f }) { return false }
  return JS.lower(to.scheme) == JS.lower(from.scheme) && JS.lower(to.host) == JS.lower(from.host)
}

private func replaceAll(_ s: Units, _ what: Units, _ with: Units) -> Units {
  guard !what.isEmpty, s.contains(what) else { return s }
  var out = Units()
  var i = 0
  while i < s.count {
    if s.hasPrefix(what, at: i) {
      out += with
      i += what.count
    } else {
      out.append(s[i])
      i += 1
    }
  }
  return out
}

private func expandTemplate(_ stored: Units) -> Units {
  let full = stored.asciiCaseInsensitivePrefix("https://") || stored.asciiCaseInsensitivePrefix("http://") ? stored : Units("https://") + stored
  return replaceAll(full, Units(storedPlaceholder), Units(bangPlaceholder))
}

public func slimBangs(_ json: String) -> String? {
  guard let list = try? parseLooseJson(json), case .array(let entries) = list else { return nil }
  var seen = Set<Units>()
  var lines: [Units] = []
  for entry in entries {
    guard entry.isObject, case .string(let s)? = entry["s"], case .array(let ts)? = entry["ts"], case .string(let u)? = entry["u"] else { continue }
    let template = u.units
    if !isValidBangTemplate(template) || template.contains(Units(storedPlaceholder)) { continue }
    let name = JS.trim(JS.collapseSpaces(s.units))
    if name.isEmpty { continue }
    var triggers: [Units] = []
    for t in ts {
      guard case .string(let text) = t else { continue }
      let trigger = JS.lower(JS.trim(text.units))
      if trigger.isEmpty || trigger.contains(where: { JS.isSpace($0) || $0 == Unit.bang }) || seen.contains(trigger) { continue }
      seen.insert(trigger)
      triggers.append(trigger)
    }
    if triggers.isEmpty { continue }
    var stored = template.asciiCaseInsensitivePrefix("https://") ? Array(template[8...]) : template
    stored = replaceAll(stored, Units(bangPlaceholder), Units(storedPlaceholder))
    lines.append(Array(triggers.joined(separator: [Unit.space])) + [Unit.tab] + name + [Unit.tab] + stored)
  }
  return lines.count >= minBangs ? Array(lines.joined(separator: [Unit.newline])).string : nil
}

private func homeOf(_ template: Units) -> Units {
  let start: Int
  if template.asciiCaseInsensitivePrefix("https://") {
    start = 8
  } else if template.asciiCaseInsensitivePrefix("http://") {
    start = 7
  } else {
    return template
  }
  var end = start
  while end < template.count && template[end] != Unit.slash && template[end] != Unit.question && template[end] != Unit.hash { end += 1 }
  return end == start ? template : Array(template[..<end]) + [Unit.slash]
}

public final class SlimBangTable: BangTable {
  private let slim: Units
  private let lines: [Units: Int]
  private let parsed = Mutex<[Units: Bang?]>([:])

  public init(_ slim: String) {
    let text = slim.units
    self.slim = text
    var lines: [Units: Int] = [:]
    var at = 0
    while at < text.count {
      let end = text[at...].firstIndex(of: Unit.newline) ?? text.count
      if let tab = text[at..<end].firstIndex(of: Unit.tab), tab > at {
        var from = at
        while from < tab {
          let space = text[from..<tab].firstIndex(of: Unit.space) ?? tab
          let trigger = Array(text[from..<space])
          if !trigger.isEmpty && lines[trigger] == nil { lines[trigger] = at }
          from = space + 1
        }
      }
      at = end + 1
    }
    self.lines = lines
  }

  public var size: Int { lines.count }

  public func get(_ trigger: String) -> Bang? {
    let key = JS.lower(trigger.units)
    if let cached = parsed.withLock({ $0[key] }) { return cached }
    var bang: Bang?
    if let at = lines[key] {
      let end = slim[at...].firstIndex(of: Unit.newline) ?? slim.count
      let fields = slim[at..<end].split(separator: Unit.tab, omittingEmptySubsequences: false)
      let name = fields.count > 1 ? Array(fields[1]) : []
      let stored = fields.count > 2 ? Array(fields[2]) : []
      let template = expandTemplate(stored)
      if !name.isEmpty && isValidBangTemplate(template) {
        bang = Bang(trigger: key.string, name: name.string, template: template.string, home: homeOf(template).string)
      }
    }
    parsed.withLock { $0[key] = .some(bang) }
    return bang
  }
}

public func bangTable(_ slim: String) -> any BangTable { SlimBangTable(slim) }

public func checkedBangTable(_ slim: String) -> (any BangTable)? {
  let text = slim.units
  if text.count > maxBangListChars { return nil }
  var count = 0
  for line in text.split(separator: Unit.newline, omittingEmptySubsequences: false) {
    let fields = line.split(separator: Unit.tab, omittingEmptySubsequences: false)
    guard fields.count == 3, !fields[0].isEmpty, !fields[1].isEmpty, !fields[2].isEmpty else { return nil }
    let triggers = fields[0].split(separator: Unit.space, omittingEmptySubsequences: false)
    if triggers.contains(where: { $0.isEmpty || $0.contains(where: { JS.isSpace($0) || $0 == Unit.bang }) }) { return nil }
    if !isValidBangTemplate(expandTemplate(Array(fields[2]))) { return nil }
    count += 1
  }
  if count < minBangs { return nil }
  let table = SlimBangTable(slim)
  return requiredTriggers.allSatisfy({ table.get($0) != nil }) ? table : nil
}

public func bangDocument(etag: String?, slim: String) -> String { "\(bangDocumentMagic)\t\(etag ?? "")\n\(slim)" }

public func readBangDocument(_ doc: String?) -> (etag: String?, table: any BangTable)? {
  guard let doc else { return nil }
  let text = doc.units
  if text.isEmpty || text.count > maxBangListChars + 1024 { return nil }
  guard let firstLine = text.firstIndex(of: Unit.newline) else { return nil }
  let head = text[..<firstLine].split(separator: Unit.tab, omittingEmptySubsequences: false)
  guard head.count <= 2, Array(head[0]) == Units(bangDocumentMagic) else { return nil }
  let etag = head.count > 1 ? Array(head[1]).string : ""
  guard let table = checkedBangTable(Array(text[(firstLine + 1)...]).string) else { return nil }
  return (etag.isEmpty ? nil : etag, table)
}

public struct JoinedBangTable: BangTable {
  public let tables: [any BangTable]

  public init(_ tables: [any BangTable]) { self.tables = tables }

  public var size: Int { tables.reduce(0) { $0 + $1.size } }

  public func get(_ trigger: String) -> Bang? {
    for table in tables {
      if let bang = table.get(trigger) { return bang }
    }
    return nil
  }
}

public func joinBangTables(_ tables: [any BangTable]) -> any BangTable { JoinedBangTable(tables) }

public func findBang(_ text: String, _ table: (any BangTable)?) -> BangMatch? {
  let u = text.units
  guard let table, u.contains(Unit.bang), JS.trimStart(u).first != Unit.question else { return nil }
  let words = JS.splitSpacesKeepingEmpty(JS.trim(u))
  let last = words.count - 1
  for at in last > 0 ? [0, last] : [0] {
    let word = words[at]
    if word.count < 2 || word[0] != Unit.bang { continue }
    guard let bang = table.get(Array(word[1...]).string) else { continue }
    let query = Array(words.enumerated().filter { $0.offset != at }.map(\.element).joined(separator: [Unit.space]))
    let url = query.isEmpty ? bang.home : fillBangTemplate(bang.template, query.string)
    if staysOnSite(url, bang.template) { return BangMatch(bang: bang, query: query.string, url: url) }
  }
  return nil
}

private let pathSpecials: Set<UInt32> = Set("\"#%:<>?[\\]^`{|}".unicodeScalars.map(\.value))

public func escapeSearchTerms(_ terms: String, inQuery: Bool) -> String {
  if inQuery {
    let encoded = JS.encodeURIComponent(terms).units
    return replaceAll(encoded, Units("%20"), [Unit.plus]).string
  }
  var out = ""
  for scalar in terms.unicodeScalars {
    if scalar.value >= 0x21 && scalar.value <= 0x7e && !pathSpecials.contains(scalar.value) {
      out.unicodeScalars.append(scalar)
    } else {
      out += JS.encodeURIComponent(String(scalar))
    }
  }
  return out
}

public func fillBangTemplate(_ template: String, _ terms: String) -> String {
  let t = template.units
  let placeholder = Units(bangPlaceholder)
  guard let at = t.index(of: placeholder) else { return template }
  let question = t.firstIndex(of: Unit.question)
  let escaped = escapeSearchTerms(terms, inQuery: question.map { at > $0 } ?? false)
  return replaceAll(t, placeholder, escaped.units).string
}

public enum BundledBangs {
  public static let etag = bundledBangListEtag
  public static let generatedAt = bundledBangListGeneratedAt
  public static let list = bundledBangList
  public static let unicodeList = bundledBangListUnicode
  public static let table: any BangTable = JoinedBangTable([SlimBangTable(list), SlimBangTable(unicodeList)])
}
