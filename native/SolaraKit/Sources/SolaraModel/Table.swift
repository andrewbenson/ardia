import Synchronization

private let tableVersions = Atomic<UInt64>(0)

func nextTableVersion() -> UInt64 {
  tableVersions.add(1, ordering: .relaxed).newValue
}

public struct Table<Value: Sendable & Equatable>: Sendable, Sequence {
  public private(set) var map: JSMap<Value>
  public private(set) var version: UInt64

  public init() {
    map = JSMap()
    version = 0
  }

  public init(_ map: JSMap<Value>) {
    self.map = map
    version = nextTableVersion()
  }

  public subscript(id: String) -> Value? {
    get { map[id] }
    set {
      map[id] = newValue
      version = nextTableVersion()
    }
  }

  public var count: Int { map.count }
  public var isEmpty: Bool { map.isEmpty }
  public var keys: [String] { map.keys }
  public var values: [Value] { map.values }
  public func contains(_ id: String) -> Bool { map.contains(id) }

  public mutating func touch() { version = nextTableVersion() }

  public mutating func remove(_ ids: some Sequence<String>) {
    for id in ids { map.removeValue(forKey: id) }
    version = nextTableVersion()
  }

  public mutating func replace(with map: JSMap<Value>) {
    self.map = map
    version = nextTableVersion()
  }

  public func changed(from previous: Table) -> Bool { version != previous.version }

  public func changedIds(from previous: Table) -> [String] {
    if version == previous.version { return [] }
    var ids: [String] = []
    for (id, value) in map where previous.map[id] != value { ids.append(id) }
    for id in previous.map.keys where !map.contains(id) { ids.append(id) }
    return ids
  }

  public func makeIterator() -> IndexingIterator<[(key: String, value: Value)]> { map.makeIterator() }

  public func filtered(_ keep: (Value) -> Bool) -> Table {
    var out = self
    out.replace(with: map.filter { keep($1) })
    return out
  }
}

extension Table: Equatable {
  public static func == (a: Table, b: Table) -> Bool { a.version == b.version || a.map == b.map }
}
