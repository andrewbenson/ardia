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
}

public struct Fields {
  public let object: JSONObject
  public let known: Set<String>
  let unreadable = UnreadableKeys()

  public init(_ object: JSONObject, known: Set<String>) {
    self.object = object
    self.known = known
  }

  public var extra: JSONObject { object.filter { key, _ in !known.contains(key) || unreadable.keys.contains(key) } }

  public var order: [String] { object.keys }

  public func absent(_ keys: [String]) -> Set<String> {
    Set(keys.filter { !object.contains($0) })
  }

  public func string(_ key: String) -> String { object[key]?.string ?? "" }
  public func optionalString(_ key: String) -> String? { object[key]?.string }
  public func bool(_ key: String) -> Bool { object[key]?.bool ?? false }
  public func optionalBool(_ key: String) -> Bool? { object[key]?.bool }
  public func number(_ key: String) -> Double { object[key]?.number ?? 0 }
  public func optionalNumber(_ key: String) -> Double? { object[key]?.number }
  public func strings(_ key: String) -> [String] { object[key]?.array?.compactMap(\.string) ?? [] }
  public func optionalStrings(_ key: String) -> [String]? { object[key]?.array?.compactMap(\.string) }
  public func numbers(_ key: String) -> [Double] { object[key]?.array?.compactMap(\.number) ?? [] }
  public func optionalNumbers(_ key: String) -> [Double]? { object[key]?.array?.compactMap(\.number) }
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
    for (key, value) in extra where !fields.contains(key) { merged[key] = value }
    return merged.ordered(by: order)
  }

  func carries(_ key: String) -> Bool { fields.contains(key) || extra.contains(key) }

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
