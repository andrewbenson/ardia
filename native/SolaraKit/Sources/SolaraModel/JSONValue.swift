import Foundation

public typealias JSONObject = JSMap<JSONValue>

public enum JSONValue: Sendable, Hashable {
  case null
  case bool(Bool)
  case number(Double)
  case string(String)
  case array([JSONValue])
  case object(JSONObject)

  public var string: String? {
    if case .string(let value) = self { return value }
    return nil
  }

  public var number: Double? {
    if case .number(let value) = self { return value }
    return nil
  }

  public var int: Int? {
    if case .number(let value) = self, value.rounded() == value, abs(value) < 9.0e15 { return Int(value) }
    return nil
  }

  public var bool: Bool? {
    if case .bool(let value) = self { return value }
    return nil
  }

  public var array: [JSONValue]? {
    if case .array(let value) = self { return value }
    return nil
  }

  public var object: JSONObject? {
    if case .object(let value) = self { return value }
    return nil
  }

  public var isNull: Bool {
    if case .null = self { return true }
    return false
  }

  public var truthy: Bool {
    switch self {
    case .null: false
    case .bool(let value): value
    case .number(let value): value != 0 && !value.isNaN
    case .string(let value): !value.isEmpty
    case .array, .object: true
    }
  }

  public subscript(key: String) -> JSONValue? {
    object?[key]
  }
}

extension JSONValue: ExpressibleByNilLiteral, ExpressibleByBooleanLiteral, ExpressibleByStringLiteral,
  ExpressibleByIntegerLiteral, ExpressibleByFloatLiteral, ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral
{
  public init(nilLiteral: ()) { self = .null }
  public init(booleanLiteral value: Bool) { self = .bool(value) }
  public init(stringLiteral value: String) { self = .string(value) }
  public init(integerLiteral value: Int) { self = .number(Double(value)) }
  public init(floatLiteral value: Double) { self = .number(value) }
  public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
  public init(dictionaryLiteral elements: (String, JSONValue)...) { self = .object(JSONObject(elements)) }
}

public extension JSONValue {
  init(_ value: String?) { self = value.map(JSONValue.string) ?? .null }
  init(_ value: Double) { self = .number(value) }
  init(_ value: Int) { self = .number(Double(value)) }
  init(_ value: Bool) { self = .bool(value) }
  init(_ values: [String]) { self = .array(values.map(JSONValue.string)) }
}
