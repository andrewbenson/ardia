import Foundation

public enum LiveAnyJSON: Codable, Sendable, Equatable {
  case null
  case bool(Bool)
  case number(Double)
  case string(String)
  case array([LiveAnyJSON])
  case object([String: LiveAnyJSON])

  public init(from decoder: Decoder) throws {
    if var list = try? decoder.unkeyedContainer() {
      var values: [LiveAnyJSON] = []
      while !list.isAtEnd { values.append(try list.decode(LiveAnyJSON.self)) }
      self = .array(values)
      return
    }
    if let keyed = try? decoder.container(keyedBy: LiveAnyKey.self) {
      var values: [String: LiveAnyJSON] = [:]
      for key in keyed.allKeys { values[key.stringValue] = try keyed.decode(LiveAnyJSON.self, forKey: key) }
      self = .object(values)
      return
    }
    let single = try decoder.singleValueContainer()
    if single.decodeNil() { self = .null }
    else if let value = try? single.decode(Bool.self) { self = .bool(value) }
    else if let value = try? single.decode(Double.self) { self = .number(value) }
    else { self = .string(try single.decode(String.self)) }
  }

  public func encode(to encoder: Encoder) throws {
    switch self {
    case .null:
      var single = encoder.singleValueContainer()
      try single.encodeNil()
    case .bool(let value):
      var single = encoder.singleValueContainer()
      try single.encode(value)
    case .number(let value):
      var single = encoder.singleValueContainer()
      try single.encode(value)
    case .string(let value):
      var single = encoder.singleValueContainer()
      try single.encode(value)
    case .array(let values):
      var list = encoder.unkeyedContainer()
      for value in values { try list.encode(value) }
    case .object(let values):
      var keyed = encoder.container(keyedBy: LiveAnyKey.self)
      for (key, value) in values { try keyed.encode(value, forKey: LiveAnyKey(key)) }
    }
  }
}

struct LiveAnyKey: CodingKey {
  var stringValue: String
  var intValue: Int? { nil }
  init(_ string: String) { stringValue = string }
  init(stringValue: String) { self.stringValue = stringValue }
  init?(intValue: Int) { nil }
}

enum UnknownKeys {
  static func read(_ decoder: Decoder, known: some Sequence<String>) -> [String: LiveAnyJSON] {
    guard let keyed = try? decoder.container(keyedBy: LiveAnyKey.self) else { return [:] }
    let skip = Set(known)
    var extra: [String: LiveAnyJSON] = [:]
    for key in keyed.allKeys where !skip.contains(key.stringValue) {
      if let value = try? keyed.decode(LiveAnyJSON.self, forKey: key) { extra[key.stringValue] = value }
    }
    return extra
  }

  static func write(_ extra: [String: LiveAnyJSON], to encoder: Encoder) throws {
    guard !extra.isEmpty else { return }
    var keyed = encoder.container(keyedBy: LiveAnyKey.self)
    for (key, value) in extra { try keyed.encode(value, forKey: LiveAnyKey(key)) }
  }
}
