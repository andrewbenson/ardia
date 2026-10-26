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

public struct Fields {
  public let object: JSONObject
  public let known: Set<String>

  public init(_ object: JSONObject, known: Set<String>) {
    self.object = object
    self.known = known
  }

  public var extra: JSONObject { object.filter { key, _ in !known.contains(key) } }

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
    return try T(value: value)
  }

  public func models<T: JSONConvertible>(_ key: String) throws -> [T] {
    try (object[key]?.array ?? []).map { try T(value: $0) }
  }

  public func optionalModels<T: JSONConvertible>(_ key: String) throws -> [T]? {
    guard let items = object[key]?.array else { return nil }
    return try items.map { try T(value: $0) }
  }

  public func stringMap(_ key: String) -> JSMap<String> {
    var out = JSMap<String>()
    for (k, v) in object[key]?.object ?? [:] { if let s = v.string { out[k] = s } }
    return out
  }
}

public struct Encoder {
  public var object: JSONObject

  public init(extra: JSONObject = [:]) {
    object = extra
  }

  public mutating func set(_ key: String, _ value: String) { object[key] = .string(value) }
  public mutating func set(_ key: String, _ value: Bool) { object[key] = .bool(value) }
  public mutating func set(_ key: String, _ value: Double) { object[key] = .number(value) }
  public mutating func set(_ key: String, _ value: [String]) { object[key] = JSONValue(value) }
  public mutating func set(_ key: String, _ value: [Double]) { object[key] = .array(value.map(JSONValue.number)) }
  public mutating func set(_ key: String, _ value: JSONValue) { object[key] = value }
  public mutating func set(_ key: String, _ value: JSMap<String>) { object[key] = .object(value.mapValues(JSONValue.string)) }
  public mutating func set<T: JSONConvertible>(_ key: String, _ value: T) { object[key] = value.jsonValue }
  public mutating func set<T: JSONConvertible>(_ key: String, _ values: [T]) { object[key] = .array(values.map(\.jsonValue)) }

  public mutating func nullable(_ key: String, _ value: String?, absent: Set<String> = []) {
    if let value { object[key] = .string(value) } else if !absent.contains(key) { object[key] = .null }
  }

  public mutating func nullable(_ key: String, _ value: [Double]?, absent: Set<String> = []) {
    if let value { set(key, value) } else if !absent.contains(key) { object[key] = .null }
  }

  public mutating func nullable<T: JSONConvertible>(_ key: String, _ value: T?, absent: Set<String> = []) {
    if let value { object[key] = value.jsonValue } else if !absent.contains(key) { object[key] = .null }
  }

  public mutating func optional(_ key: String, _ value: String?) { if let value { object[key] = .string(value) } }
  public mutating func optional(_ key: String, _ value: Bool?) { if let value { object[key] = .bool(value) } }
  public mutating func optional(_ key: String, _ value: Double?) { if let value { object[key] = .number(value) } }
  public mutating func optional(_ key: String, _ value: [Double]?) { if let value { set(key, value) } }
  public mutating func optional(_ key: String, _ value: [String]?) { if let value { set(key, value) } }
  public mutating func optional(_ key: String, _ value: JSONValue?) { if let value { object[key] = value } }
  public mutating func optional<T: JSONConvertible>(_ key: String, _ value: T?) { if let value { object[key] = value.jsonValue } }
  public mutating func optional<T: JSONConvertible>(_ key: String, _ values: [T]?) { if let values { set(key, values) } }
}
