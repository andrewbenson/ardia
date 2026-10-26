import Foundation

public enum JSONValue: Sendable, Equatable {
  case null
  case bool(Bool)
  case number(Double)
  case string(String)
  case array([JSONValue])
  case object([(key: String, value: JSONValue)])

  public static func == (a: JSONValue, b: JSONValue) -> Bool {
    switch (a, b) {
    case (.null, .null): true
    case (.bool(let x), .bool(let y)): x == y
    case (.number(let x), .number(let y)): x == y || (x.isNaN && y.isNaN)
    case (.string(let x), .string(let y)): x.sameUnits(y)
    case (.array(let x), .array(let y)): x == y
    case (.object(let x), .object(let y)): x.count == y.count && zip(x, y).allSatisfy { $0.key.sameUnits($1.key) && $0.value == $1.value }
    default: false
    }
  }

  public subscript(key: String) -> JSONValue? {
    guard case .object(let pairs) = self else { return nil }
    return pairs.first { $0.key.sameUnits(key) }?.value
  }

  public subscript(index: Int) -> JSONValue? {
    guard case .array(let items) = self, index >= 0, index < items.count else { return nil }
    return items[index]
  }

  public var string: String? {
    if case .string(let s) = self { return s }
    return nil
  }

  public var array: [JSONValue]? {
    if case .array(let a) = self { return a }
    return nil
  }

  public var isObject: Bool {
    if case .object = self { return true }
    return false
  }

  var truthy: Bool {
    switch self {
    case .null: false
    case .bool(let b): b
    case .number(let n): n != 0 && !n.isNaN
    case .string(let s): !s.isEmpty
    case .array, .object: true
    }
  }

  var jsString: String {
    switch self {
    case .null: "null"
    case .bool(let b): b ? "true" : "false"
    case .number(let n): JS.numberToString(n)
    case .string(let s): s
    case .array(let items): items.map { $0 == .null ? "" : $0.jsString }.joined(separator: ",")
    case .object: "[object Object]"
    }
  }

  public init(parsing text: String) throws {
    var parser = JSONParser(text.units)
    self = try parser.parseDocument()
  }

  public init(parsing data: Data) throws {
    try self.init(parsing: String(decoding: data, as: UTF8.self))
  }

  public init(_ any: Any?) {
    switch any {
    case nil, is NSNull: self = .null
    case let n as NSNumber where CFGetTypeID(n) == CFBooleanGetTypeID(): self = .bool(n.boolValue)
    case let b as Bool: self = .bool(b)
    case let n as NSNumber: self = .number(n.doubleValue)
    case let s as String: self = .string(s)
    case let a as [Any?]: self = .array(a.map(JSONValue.init))
    case let a as [Any]: self = .array(a.map { JSONValue($0) })
    case let pairs as KeyValuePairs<String, Any?>: self = .object(pairs.map { ($0.key, JSONValue($0.value)) })
    case let d as [String: Any]: self = .object(d.keys.sorted().map { ($0, JSONValue(d[$0])) })
    default: self = .null
    }
  }
}

public struct JSONSyntaxError: Error, Sendable {}

struct JSONParser {
  let text: Units
  var i = 0

  init(_ text: Units) { self.text = text }

  mutating func parseDocument() throws -> JSONValue {
    skipSpace()
    let value = try parseValue()
    skipSpace()
    if i != text.count { throw JSONSyntaxError() }
    return value
  }

  mutating func skipSpace() {
    while i < text.count, text[i] == 0x20 || text[i] == 0x09 || text[i] == 0x0a || text[i] == 0x0d { i += 1 }
  }

  mutating func literal(_ word: String) -> Bool {
    let u = Units(word)
    guard text.hasPrefix(u, at: i) else { return false }
    i += u.count
    return true
  }

  mutating func parseValue() throws -> JSONValue {
    guard i < text.count else { throw JSONSyntaxError() }
    switch text[i] {
    case 0x7b: return try parseObject()
    case 0x5b: return try parseArray()
    case 0x22: return .string(try parseString())
    case 0x74: if literal("true") { return .bool(true) }
    case 0x66: if literal("false") { return .bool(false) }
    case 0x6e: if literal("null") { return .null }
    default: return .number(try parseNumber())
    }
    throw JSONSyntaxError()
  }

  mutating func parseObject() throws -> JSONValue {
    i += 1
    var pairs: [(key: String, value: JSONValue)] = []
    var index: [Units: Int] = [:]
    skipSpace()
    if i < text.count && text[i] == 0x7d {
      i += 1
      return .object(orderedLikeJS(pairs))
    }
    while true {
      skipSpace()
      guard i < text.count, text[i] == 0x22 else { throw JSONSyntaxError() }
      let key = try parseString()
      skipSpace()
      guard i < text.count, text[i] == 0x3a else { throw JSONSyntaxError() }
      i += 1
      skipSpace()
      let value = try parseValue()
      let keyUnits = key.units
      if let at = index[keyUnits] {
        pairs[at].value = value
      } else {
        index[keyUnits] = pairs.count
        pairs.append((key, value))
      }
      skipSpace()
      guard i < text.count else { throw JSONSyntaxError() }
      if text[i] == 0x2c {
        i += 1
        continue
      }
      if text[i] == 0x7d {
        i += 1
        return .object(orderedLikeJS(pairs))
      }
      throw JSONSyntaxError()
    }
  }

  private func arrayIndex(_ key: String) -> UInt32? {
    let u = key.units
    guard !u.isEmpty, u.count <= 10, u.allSatisfy(Unit.isDigit), u.count == 1 || u[0] != Unit.zero, let n = UInt64(key), n < 4_294_967_295 else { return nil }
    return UInt32(n)
  }

  private func orderedLikeJS(_ pairs: [(key: String, value: JSONValue)]) -> [(key: String, value: JSONValue)] {
    let numeric = pairs.compactMap { pair in arrayIndex(pair.key).map { ($0, pair) } }.sorted { $0.0 < $1.0 }.map(\.1)
    if numeric.isEmpty { return pairs }
    return numeric + pairs.filter { arrayIndex($0.key) == nil }
  }

  mutating func parseArray() throws -> JSONValue {
    i += 1
    var items: [JSONValue] = []
    skipSpace()
    if i < text.count && text[i] == 0x5d {
      i += 1
      return .array(items)
    }
    while true {
      skipSpace()
      items.append(try parseValue())
      skipSpace()
      guard i < text.count else { throw JSONSyntaxError() }
      if text[i] == 0x2c {
        i += 1
        continue
      }
      if text[i] == 0x5d {
        i += 1
        return .array(items)
      }
      throw JSONSyntaxError()
    }
  }

  mutating func parseString() throws -> String {
    i += 1
    var out = Units()
    while true {
      guard i < text.count else { throw JSONSyntaxError() }
      let c = text[i]
      if c == 0x22 {
        i += 1
        return out.string
      }
      if c < 0x20 { throw JSONSyntaxError() }
      if c != 0x5c {
        out.append(c)
        i += 1
        continue
      }
      guard i + 1 < text.count else { throw JSONSyntaxError() }
      let e = text[i + 1]
      i += 2
      switch e {
      case 0x22, 0x5c, 0x2f: out.append(e)
      case 0x62: out.append(0x08)
      case 0x66: out.append(0x0c)
      case 0x6e: out.append(0x0a)
      case 0x72: out.append(0x0d)
      case 0x74: out.append(0x09)
      case 0x75:
        guard i + 4 <= text.count, let v = UInt16(String(units: text[i..<(i + 4)]), radix: 16),
          text[i..<(i + 4)].allSatisfy({ Unit.isDigit($0) || (0x61...0x66).contains($0) || (0x41...0x46).contains($0) })
        else { throw JSONSyntaxError() }
        out.append(v)
        i += 4
      default: throw JSONSyntaxError()
      }
    }
  }

  mutating func parseNumber() throws -> Double {
    let start = i
    if i < text.count && text[i] == Unit.dash { i += 1 }
    guard i < text.count, Unit.isDigit(text[i]) else { throw JSONSyntaxError() }
    if text[i] == Unit.zero {
      i += 1
    } else {
      while i < text.count && Unit.isDigit(text[i]) { i += 1 }
    }
    if i < text.count && text[i] == Unit.dot {
      i += 1
      guard i < text.count, Unit.isDigit(text[i]) else { throw JSONSyntaxError() }
      while i < text.count && Unit.isDigit(text[i]) { i += 1 }
    }
    if i < text.count && (text[i] == 0x65 || text[i] == 0x45) {
      i += 1
      if i < text.count && (text[i] == Unit.plus || text[i] == Unit.dash) { i += 1 }
      guard i < text.count, Unit.isDigit(text[i]) else { throw JSONSyntaxError() }
      while i < text.count && Unit.isDigit(text[i]) { i += 1 }
    }
    return JS.number(String(units: text[start..<i]))
  }
}
