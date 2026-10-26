import Foundation
import Testing

@testable import SolaraOmnibox

enum Fixture {
  static func url(_ name: String) -> URL {
    if let dir = ProcessInfo.processInfo.environment["SOLARA_OMNIBOX_FIXTURES"], !dir.isEmpty {
      return URL(fileURLWithPath: dir).appendingPathComponent(name)
    }
    return URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures").appendingPathComponent(name)
  }

  static func load(_ name: String) throws -> ParsedJSON {
    try ParsedJSON(parsing: Data(contentsOf: url(name)))
  }
}

extension ParsedJSON {
  var items: [ParsedJSON] { array ?? [] }
  var str: String { string ?? "" }
  var isNull: Bool { self == .null }

  var double: Double {
    switch self {
    case .number(let n): return n
    case .string(let s):
      switch s {
      case "NaN": return .nan
      case "Infinity": return .infinity
      case "-Infinity": return -.infinity
      case "-0": return -0.0
      default: return Double(s) ?? .nan
      }
    default: return .nan
    }
  }

  var int: Int { Int(double) }
  var bool: Bool { self == .bool(true) }
  var optionalString: String? { isNull ? nil : string }
}

func js(_ s: String?) -> ParsedJSON { s.map(ParsedJSON.string) ?? .null }
func js(_ b: Bool) -> ParsedJSON { .bool(b) }
func js(_ x: Double) -> ParsedJSON {
  if x.isNaN { return .string("NaN") }
  if x.isInfinite { return .string(x < 0 ? "-Infinity" : "Infinity") }
  if x == 0 && x.sign == .minus { return .string("-0") }
  return .number(x)
}
func js(_ list: [ParsedJSON]) -> ParsedJSON { .array(list) }
func obj(_ pairs: KeyValuePairs<String, ParsedJSON?>) -> ParsedJSON {
  .object(pairs.compactMap { pair in pair.value.map { (pair.key, $0) } })
}

func json(_ s: Suggestion) -> ParsedJSON {
  switch s {
  case .page(let url, let title, let favicon, let tabId, let bookmarked, let visited):
    return obj([
      "kind": .string("page"), "url": .string(url), "title": .string(title), "favicon": js(favicon),
      "tabId": tabId.map(ParsedJSON.string), "bookmarked": bookmarked ? .bool(true) : nil, "visited": visited ? .bool(true) : nil,
    ])
  case .search(let query, let url, let engine, let suggested, let bang):
    return obj([
      "kind": .string("search"), "query": .string(query), "url": .string(url), "engine": .string(engine),
      "suggested": suggested ? .bool(true) : nil, "bang": bang ? .bool(true) : nil,
    ])
  case .calc(let expression, let value, let url):
    return obj(["kind": .string("calc"), "expression": .string(expression), "value": .string(value), "url": .string(url)])
  case .action(let id, let title, let icon, let hint):
    return obj(["kind": .string("action"), "id": .string(id), "title": .string(title), "icon": icon.map(ParsedJSON.string), "hint": hint.map(ParsedJSON.string)])
  case .create(let id, let title, let url, let site):
    return obj(["kind": .string("create"), "id": .string(id), "title": .string(title), "url": .string(url), "site": .string(site)])
  case .extension(let id, let title, let icon, let open):
    return obj(["kind": .string("extension"), "id": .string(id), "title": .string(title), "icon": js(icon), "open": .string(open.rawValue)])
  }
}

func json(_ r: SuggestionResult) -> ParsedJSON {
  obj(["items": .array(r.items.map(json)), "completion": .string(r.completion)])
}

func json(_ b: Bang?) -> ParsedJSON {
  guard let b else { return .null }
  return obj(["trigger": .string(b.trigger), "name": .string(b.name), "template": .string(b.template), "home": .string(b.home)])
}

func json(_ m: BangMatch?) -> ParsedJSON {
  guard let m else { return .null }
  return obj(["bang": json(m.bang), "query": .string(m.query), "url": .string(m.url)])
}

func json(_ s: SearchScope?) -> ParsedJSON {
  guard let s else { return .null }
  return obj(["kind": .string(s.kind.rawValue), "name": .string(s.name), "host": .string(s.host), "url": .string(s.url), "engineId": s.engineId.map(ParsedJSON.string)])
}

func scope(_ v: ParsedJSON) -> SearchScope? {
  guard v.isObject else { return nil }
  return SearchScope(kind: SearchScopeKind(rawValue: v["kind"]!.str)!, name: v["name"]!.str, host: v["host"]!.str, url: v["url"]!.str, engineId: v["engineId"]?.string)
}

func same(_ a: ParsedJSON?, _ b: ParsedJSON?) -> Bool {
  switch (a ?? .null, b ?? .null) {
  case (.object(let x), .object(let y)):
    guard x.count == y.count else { return false }
    for (key, value) in x {
      guard let other = y.first(where: { $0.key.sameUnits(key) }) else { return false }
      if !same(value, other.value) { return false }
    }
    return true
  case (.array(let x), .array(let y)):
    return x.count == y.count && zip(x, y).allSatisfy { same($0, $1) }
  case (.number, .string), (.string, .number):
    return (a ?? .null).double.bitPattern == (b ?? .null).double.bitPattern
  case (let x, let y):
    return x == y
  }
}

func describe(_ v: ParsedJSON?) -> String {
  guard let v else { return "undefined" }
  switch v {
  case .null: return "null"
  case .bool(let b): return b ? "true" : "false"
  case .number(let n): return JS.numberToString(n)
  case .string(let s): return "\"" + s.unicodeScalars.map { $0.value < 0x20 || $0.value == 0x2028 || ($0.value >= 0x7f && $0.value < 0xa1) ? String(format: "\\u%04x", $0.value) : String($0) }.joined() + "\""
  case .array(let items): return "[" + items.map { describe($0) }.joined(separator: ", ") + "]"
  case .object(let pairs): return "{" + pairs.map { "\($0.key): \(describe($0.value))" }.joined(separator: ", ") + "}"
  }
}

struct Mismatches {
  var total = 0
  var compared = 0
  var lines: [String] = []

  mutating func check(_ label: @autoclosure () -> String, _ got: ParsedJSON?, _ want: ParsedJSON?) {
    compared += 1
    if same(got, want) { return }
    total += 1
    if lines.count < 25 { lines.append("\(label())\n    got:  \(describe(got))\n    want: \(describe(want))") }
  }

  mutating func check(_ label: @autoclosure () -> String, _ got: String?, _ want: ParsedJSON?) {
    check(label(), js(got), want)
  }

  var report: String { "\(total) of \(compared) differ:\n" + lines.joined(separator: "\n") }
}
