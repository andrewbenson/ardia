import Foundation

public enum RekeyStoreKind: String, Codable, Sendable {
  case sqlite, prefs, nigori, blob
}

public struct RekeyPreflight: Codable, Sendable {
  public var mockKeyed: Bool
  public var oldKeyedValues: Int
  public var blocking: [String]
  public var notes: [String]

  public init(mockKeyed: Bool, oldKeyedValues: Int, blocking: [String], notes: [String]) {
    self.mockKeyed = mockKeyed
    self.oldKeyedValues = oldKeyedValues
    self.blocking = blocking
    self.notes = notes
  }
}

public struct RekeyStagedStore: Codable, Sendable, Equatable {
  public var relativePath: String
  public var kind: RekeyStoreKind
  public var values: Int

  public init(relativePath: String, kind: RekeyStoreKind, values: Int) {
    self.relativePath = relativePath
    self.kind = kind
    self.values = values
  }
}

public struct RekeyStageReport: Codable, Sendable, Equatable {
  public var stores: [RekeyStagedStore]
  public var discard: [String]
  public var notes: [String]

  public init(stores: [RekeyStagedStore], discard: [String], notes: [String] = []) {
    self.stores = stores
    self.discard = discard
    self.notes = notes
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    stores = try container.decode([RekeyStagedStore].self, forKey: .stores)
    discard = try container.decode([String].self, forKey: .discard)
    notes = try container.decodeIfPresent([String].self, forKey: .notes) ?? []
  }
}

public protocol RekeyStoreOperations {
  func preflight(userDataDir: URL, oldSecret: Data) -> RekeyPreflight
  func stage(userDataDir: URL, stagingDir: URL, oldSecret: Data, newSecret: Data) throws -> RekeyStageReport
  func verify(file: URL, kind: RekeyStoreKind, newSecret: Data, oldSecret: Data, expectedValues: Int) -> Bool
}
