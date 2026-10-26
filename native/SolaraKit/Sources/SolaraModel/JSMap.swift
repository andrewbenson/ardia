public struct JSMap<Value>: Sequence {
  private var indexKeys: [UInt32] = []
  private var namedKeys: [String] = []
  private var storage: [String: Value] = [:]

  public init() {}

  public init(_ pairs: [(String, Value)]) {
    for (key, value) in pairs { self[key] = value }
  }

  public static func arrayIndex(_ key: String) -> UInt32? {
    guard let first = key.utf8.first, key.utf8.count <= 10 else { return nil }
    if first == UInt8(ascii: "0") { return key.utf8.count == 1 ? 0 : nil }
    var value: UInt64 = 0
    for byte in key.utf8 {
      guard byte >= UInt8(ascii: "0"), byte <= UInt8(ascii: "9") else { return nil }
      value = value * 10 + UInt64(byte - UInt8(ascii: "0"))
    }
    return value < 4_294_967_295 ? UInt32(value) : nil
  }

  public var count: Int { storage.count }
  public var isEmpty: Bool { storage.isEmpty }

  public var keys: [String] {
    if indexKeys.isEmpty { return namedKeys }
    return indexKeys.map(String.init) + namedKeys
  }

  public var values: [Value] { keys.map { storage[$0]! } }

  public subscript(key: String) -> Value? {
    get { storage[key] }
    set {
      if let newValue {
        if storage.updateValue(newValue, forKey: key) == nil { insertKey(key) }
      } else if storage.removeValue(forKey: key) != nil {
        removeKey(key)
      }
    }
  }

  public func contains(_ key: String) -> Bool { storage[key] != nil }

  @discardableResult
  public mutating func removeValue(forKey key: String) -> Value? {
    guard let old = storage.removeValue(forKey: key) else { return nil }
    removeKey(key)
    return old
  }

  public mutating func removeAll() {
    indexKeys = []
    namedKeys = []
    storage = [:]
  }

  public func makeIterator() -> IndexingIterator<[(key: String, value: Value)]> {
    keys.map { (key: $0, value: storage[$0]!) }.makeIterator()
  }

  public func mapValues<T>(_ transform: (Value) throws -> T) rethrows -> JSMap<T> {
    var out = JSMap<T>()
    out.indexKeys = indexKeys
    out.namedKeys = namedKeys
    out.storage = try storage.mapValues(transform)
    return out
  }

  public func filter(_ isIncluded: (String, Value) throws -> Bool) rethrows -> JSMap<Value> {
    var out = JSMap<Value>()
    for key in keys where try isIncluded(key, storage[key]!) { out[key] = storage[key]! }
    return out
  }

  private mutating func insertKey(_ key: String) {
    if let index = Self.arrayIndex(key) {
      var low = 0
      var high = indexKeys.count
      while low < high {
        let mid = (low + high) / 2
        if indexKeys[mid] < index { low = mid + 1 } else { high = mid }
      }
      indexKeys.insert(index, at: low)
    } else {
      namedKeys.append(key)
    }
  }

  private mutating func removeKey(_ key: String) {
    if let index = Self.arrayIndex(key) {
      if let at = indexKeys.firstIndex(of: index) { indexKeys.remove(at: at) }
    } else if let at = namedKeys.lastIndex(of: key) {
      namedKeys.remove(at: at)
    }
  }
}

extension JSMap: Equatable where Value: Equatable {
  public static func == (lhs: JSMap, rhs: JSMap) -> Bool {
    lhs.keys == rhs.keys && lhs.storage == rhs.storage
  }
}

extension JSMap: Hashable where Value: Hashable {
  public func hash(into hasher: inout Hasher) {
    hasher.combine(keys)
    for key in keys { hasher.combine(storage[key]) }
  }
}

extension JSMap: Sendable where Value: Sendable {}

extension JSMap: ExpressibleByDictionaryLiteral {
  public init(dictionaryLiteral elements: (String, Value)...) {
    self.init(elements)
  }
}
