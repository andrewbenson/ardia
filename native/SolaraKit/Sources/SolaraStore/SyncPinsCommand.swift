import SolaraModel

struct SyncPinsApplyRequest: Sendable {
  enum Kind: String, Sendable {
    case pins, rows, order, looks, homes, tileFolders
  }

  let profileId: String
  let kind: Kind
  let visible: [(key: String, value: JSONValue)]
  let changed: [String]
  let base: JSONObject
  let known: Set<JSKey>
  let now: Double
  let horizon: Double

  init(_ args: [JSONValue]) throws {
    guard args.count == 2, let profileId = args[0].string, let payload = args[1].object,
      let name = payload["kind"]?.string, let kind = Kind(rawValue: name),
      let entries = payload["visible"]?.array, let base = payload["base"]?.object,
      let now = payload["now"]?.number, now.isFinite,
      let horizon = payload["horizon"]?.number, horizon.isFinite
    else { throw CommandError("syncPinsApply: invalid frozen inputs") }
    self.profileId = profileId
    self.kind = kind
    self.base = base
    self.now = now
    self.horizon = horizon
    visible = try entries.map { entry in
      guard let pair = entry.array, pair.count == 2, let key = pair[0].string else {
        throw CommandError("syncPinsApply: visible entry must be a key and value pair")
      }
      return (key, pair[1])
    }
    changed = try Self.strings(payload["changed"])
    known = Set(try Self.strings(payload["known"]).map(JSKey.init))
  }

  static func strings(_ value: JSONValue?) throws -> [String] {
    guard let list = value?.array else { throw CommandError("syncPinsApply: keys must be a string array") }
    return try list.map {
      guard let key = $0.string else { throw CommandError("syncPinsApply: key is not a string") }
      return key
    }
  }

  func apply(_ session: Session) -> JSONValue {
    switch kind {
    case .pins:
      return .bool(session.applySyncedPins(profileId, visible, changed, { base[$0] }, known: { known.contains(JSKey($0)) }, now: now, horizon: horizon) ?? true)
    case .rows:
      return .bool(session.applySyncedPinRows(profileId, visible, changed, { base[$0] }))
    case .order:
      return .bool(session.applySyncedPinOrder(profileId, visible))
    case .looks:
      return .bool(session.applySyncedGroupLooks(profileId, visible, changed))
    case .homes:
      return session.applySyncedPinHomes(profileId, visible, changed, { base[$0] }).map { .array($0.map(JSONValue.string)) } ?? .bool(true)
    case .tileFolders:
      return .bool(session.applySyncedTileFolders(profileId, visible, changed))
    }
  }
}

struct SettledPinChoices: Sendable {
  let profileId: String
  let published: JSMap<Double>

  init(_ args: [JSONValue]) throws {
    guard args.count == 2, let profileId = args[0].string, let stamps = args[1].object else {
      throw CommandError("settlePinChoices: invalid profile or stamps")
    }
    self.profileId = profileId
    published = try JSMap(stamps.map { key, value in
      guard let stamp = value.number, stamp.isFinite else { throw CommandError("settlePinChoices: stamp is not a finite number") }
      return (key, stamp)
    })
  }

  func apply(_ session: Session) {
    session.memory.fromSyncDepth += 1
    defer { session.memory.fromSyncDepth -= 1 }
    session.settlePinChoices(profileId, published)
    session.result = .bool(true)
  }
}
