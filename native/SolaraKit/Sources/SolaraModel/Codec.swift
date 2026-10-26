import Synchronization

public struct ModelDecodeError: Error, CustomStringConvertible {
  public let description: String
  public init(_ description: String) { self.description = description }
}

public protocol JSONConvertible: Sendable, Equatable {
  init(json: JSONObject) throws
  var json: JSONObject { get }
}

public extension JSONConvertible {
  init(value: JSONValue) throws {
    guard let object = value.object else { throw ModelDecodeError("\(Self.self) is not an object") }
    try self.init(json: object)
  }

  var jsonValue: JSONValue { .object(json) }
}

public final class DecodeLog: Sendable {
  @TaskLocal public static var current: DecodeLog?

  let entries = Mutex<[String]>([])

  public init() {}

  public var notes: [String] { entries.withLock { $0 } }

  public static func note(_ text: String) {
    current?.entries.withLock { $0.append(text) }
  }

  public static func collecting<R>(_ body: () throws -> R) rethrows -> (R, [String]) {
    let log = DecodeLog()
    let result = try $current.withValue(log) { try body() }
    return (result, log.notes)
  }
}

final class UnreadableKeys: @unchecked Sendable {
  var keys: Set<String> = []
  var coerced = JSONObject()
}

public let coercedKey = "\u{0}coerced"

public struct Fields {
  public let object: JSONObject
  public let known: Set<String>
  let unreadable = UnreadableKeys()

  public init(_ object: JSONObject, known: Set<String>) {
    self.object = object
    self.known = known
  }

  public var extra: JSONObject {
    var out = object.filter { key, _ in (!known.contains(key) || unreadable.keys.contains(key)) && key != coercedKey }
    var coerced = object[coercedKey]?.object ?? JSONObject()
    for (key, record) in unreadable.coerced { coerced[key] = record }
    if !coerced.isEmpty { out[coercedKey] = .object(coerced) }
    return out
  }

  public var order: [String] { object.keys }

  public func absent(_ keys: [String]) -> Set<String> {
    Set(keys.filter { !object.contains($0) })
  }

  func coerce<T>(_ key: String, to fallback: T, as decoded: JSONValue) -> T {
    var record: JSONObject = ["decoded": decoded]
    if let raw = object[key] {
      record["raw"] = raw
      unreadable.keys.insert(key)
      DecodeLog.note("kept \(key) of the wrong type as written")
    }
    unreadable.coerced[key] = .object(record)
    return fallback
  }

  func wrongType<T>(_ key: String, _ read: (JSONValue) -> T?) -> (T?, Bool) {
    guard let raw = object[key], !raw.isNull else { return (nil, false) }
    guard let value = read(raw) else { return (nil, true) }
    return (value, false)
  }

  public func string(_ key: String) -> String {
    if let value = object[key]?.string { return value }
    return coerce(key, to: "", as: "")
  }

  public func optionalString(_ key: String) -> String? {
    let (value, wrong) = wrongType(key, \.string)
    return wrong ? coerce(key, to: nil, as: .null) : value
  }

  public func bool(_ key: String) -> Bool {
    if let value = object[key]?.bool { return value }
    return coerce(key, to: false, as: false)
  }

  public func optionalBool(_ key: String) -> Bool? {
    let (value, wrong) = wrongType(key, \.bool)
    return wrong ? coerce(key, to: nil, as: .null) : value
  }

  public func number(_ key: String, default fallback: Double = 0) -> Double {
    if let value = object[key]?.number { return value }
    return coerce(key, to: fallback, as: .number(fallback))
  }

  public func optionalNumber(_ key: String) -> Double? {
    let (value, wrong) = wrongType(key, \.number)
    return wrong ? coerce(key, to: nil, as: .null) : value
  }

  static func all<T>(_ items: [JSONValue], _ read: (JSONValue) -> T?) -> [T]? {
    var out: [T] = []
    out.reserveCapacity(items.count)
    for item in items {
      guard let value = read(item) else { return nil }
      out.append(value)
    }
    return out
  }

  public func strings(_ key: String) -> [String] {
    if let items = object[key]?.array { return items.compactMap(\.string) }
    return coerce(key, to: [], as: .array([]))
  }

  public func optionalStrings(_ key: String) -> [String]? {
    let (value, wrong) = wrongType(key) { $0.array?.compactMap(\.string) }
    return wrong ? coerce(key, to: nil, as: .null) : value
  }

  public func numbers(_ key: String) -> [Double] {
    if let items = object[key]?.array, let values = Self.all(items, \.number) { return values }
    return coerce(key, to: [], as: .array([]))
  }

  public func optionalNumbers(_ key: String) -> [Double]? {
    let (value, wrong) = wrongType(key) { $0.array.flatMap { Self.all($0, \.number) } }
    return wrong ? coerce(key, to: nil, as: .null) : value
  }

  public func value(_ key: String) -> JSONValue? { object[key] }

  public func model<T: JSONConvertible>(_ key: String) throws -> T? {
    guard let value = object[key], !value.isNull else { return nil }
    do {
      return try T(value: value)
    } catch {
      unreadable.keys.insert(key)
      DecodeLog.note("kept unreadable \(key) as written: \(error)")
      return nil
    }
  }

  public func models<T: JSONConvertible>(_ key: String) throws -> [T] {
    Self.readable(object[key]?.array ?? [], key)
  }

  public func strictModels<T: JSONConvertible>(_ key: String) throws -> [T] {
    try (object[key]?.array ?? []).map { try T(value: $0) }
  }

  public func optionalModels<T: JSONConvertible>(_ key: String) throws -> [T]? {
    guard let items = object[key]?.array else { return nil }
    return Self.readable(items, key)
  }

  static func readable<T: JSONConvertible>(_ items: [JSONValue], _ key: String) -> [T] {
    items.compactMap { item in
      do {
        return try T(value: item)
      } catch {
        DecodeLog.note("dropped an unreadable item of \(key): \(error)")
        return nil
      }
    }
  }

  public func stringMap(_ key: String) -> JSMap<String> {
    var out = JSMap<String>()
    for (k, v) in object[key]?.object ?? [:] { if let s = v.string { out[k] = s } }
    return out
  }
}

public extension JSMap where Value == JSONValue {
  func ordered(by order: [String]?) -> JSONObject {
    guard let order else { return self }
    var out = JSONObject()
    for key in order { if let value = self[key] { out[key] = value } }
    for (key, value) in self where !out.contains(key) { out[key] = value }
    return out
  }
}

public struct Encoder {
  var fields = JSONObject()
  let extra: JSONObject
  let order: [String]?

  public init(extra: JSONObject = [:], order: [String]? = nil) {
    self.extra = extra
    self.order = order
  }

  public var object: JSONObject {
    var merged = fields
    for (key, value) in extra where !fields.contains(key) && key != coercedKey { merged[key] = value }
    for (key, record) in extra[coercedKey]?.object ?? [:] {
      guard let decoded = record["decoded"] else { continue }
      let current = merged[key]
      guard current == decoded || (current == nil && decoded == .null) else { continue }
      if let raw = record["raw"] { merged[key] = raw } else { _ = merged.removeValue(forKey: key) }
    }
    return merged.ordered(by: order)
  }

  func carries(_ key: String) -> Bool { fields.contains(key) || (key != coercedKey && extra.contains(key)) }

  public mutating func set(_ key: String, _ value: String) { fields[key] = .string(value) }
  public mutating func set(_ key: String, _ value: Bool) { fields[key] = .bool(value) }
  public mutating func set(_ key: String, _ value: Double) { fields[key] = .number(value) }
  public mutating func set(_ key: String, _ value: [String]) { fields[key] = JSONValue(value) }
  public mutating func set(_ key: String, _ value: [Double]) { fields[key] = .array(value.map(JSONValue.number)) }
  public mutating func set(_ key: String, _ value: JSONValue) { fields[key] = value }
  public mutating func set(_ key: String, _ value: JSMap<String>) { fields[key] = .object(value.mapValues(JSONValue.string)) }
  public mutating func set<T: JSONConvertible>(_ key: String, _ value: T) { fields[key] = value.jsonValue }
  public mutating func set<T: JSONConvertible>(_ key: String, _ values: [T]) { fields[key] = .array(values.map(\.jsonValue)) }

  public mutating func nullable(_ key: String, _ value: String?, absent: Set<String> = []) {
    if let value { fields[key] = .string(value) } else if !absent.contains(key) && !carries(key) { fields[key] = .null }
  }

  public mutating func nullable(_ key: String, _ value: [Double]?, absent: Set<String> = []) {
    if let value { set(key, value) } else if !absent.contains(key) && !carries(key) { fields[key] = .null }
  }

  public mutating func nullable<T: JSONConvertible>(_ key: String, _ value: T?, absent: Set<String> = []) {
    if let value { fields[key] = value.jsonValue } else if !absent.contains(key) && !carries(key) { fields[key] = .null }
  }

  public mutating func optional(_ key: String, _ value: String?) { if let value { fields[key] = .string(value) } }
  public mutating func optional(_ key: String, _ value: Bool?) { if let value { fields[key] = .bool(value) } }
  public mutating func optional(_ key: String, _ value: Double?) { if let value { fields[key] = .number(value) } }
  public mutating func optional(_ key: String, _ value: [Double]?) { if let value { set(key, value) } }
  public mutating func optional(_ key: String, _ value: [String]?) { if let value { set(key, value) } }
  public mutating func optional(_ key: String, _ value: JSONValue?) { if let value { fields[key] = value } }
  public mutating func optional<T: JSONConvertible>(_ key: String, _ value: T?) { if let value { fields[key] = value.jsonValue } }
  public mutating func optional<T: JSONConvertible>(_ key: String, _ values: [T]?) { if let values { set(key, values) } }
}
