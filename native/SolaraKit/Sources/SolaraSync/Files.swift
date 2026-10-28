import SolaraModel

public struct Origin: Sendable, Equatable {
  public var device: String
  public var seq: Double

  public init(_ device: String, _ seq: Double) {
    self.device = device
    self.seq = seq
  }

  init(json: JSONValue?) {
    let items = json?.array ?? []
    device = items.first?.string ?? ""
    seq = items.count > 1 ? items[1].number ?? .nan : .nan
  }

  var json: JSONValue { [.string(device), .number(seq)] }
}

public struct SyncRecord: Sendable, Equatable {
  public var h: HLC
  public var v: JSONValue
  public var o: Origin
  public var unknown = JSONObject()

  public init(h: HLC, v: JSONValue, o: Origin) {
    self.h = h
    self.v = v
    self.o = o
  }

  init(json: JSONValue) {
    h = json["h"]?.string ?? ""
    v = json["v"] ?? .null
    o = Origin(json: json["o"])
    unknown = unknownKeys(json, ["h", "v", "o"])
  }

  var json: JSONValue { withUnknown(["h": .string(h), "v": v, "o": o.json], unknown) }
}

public struct Op: Sendable, Equatable {
  public var k: String
  public var h: HLC
  public var v: JSONValue
  public var unknown = JSONObject()

  public init(k: String, h: HLC, v: JSONValue) {
    self.k = k
    self.h = h
    self.v = v
  }

  init(json: JSONValue) {
    k = json["k"]?.string ?? ""
    h = json["h"]?.string ?? ""
    v = json["v"] ?? .null
    unknown = unknownKeys(json, ["k", "h", "v"])
  }

  var json: JSONValue { withUnknown(["k": .string(k), "h": .string(h), "v": v], unknown) }
}

public struct LogFile: Sendable, Equatable {
  public var device: String
  public var seq: Double
  public var at: Double
  public var ops: [Op]
  public var unknown = JSONObject()

  public init(device: String, seq: Double, at: Double, ops: [Op]) {
    self.device = device
    self.seq = seq
    self.at = at
    self.ops = ops
  }

  public init(json: JSONValue) {
    device = json["device"]?.string ?? ""
    seq = json["seq"]?.number ?? .nan
    at = json["at"]?.number ?? .nan
    ops = (json["ops"]?.array ?? []).map(Op.init(json:))
    unknown = unknownKeys(json, ["v", "kind", "device", "seq", "at", "ops"])
  }

  public var json: JSONValue {
    withUnknown(["v": 1, "kind": "log", "device": .string(device), "seq": .number(seq), "at": .number(at), "ops": .array(ops.map(\.json))], unknown)
  }
}

public struct SnapshotFile: Sendable, Equatable {
  public var device: String
  public var at: Double
  public var vv: JSMap<Double>
  public var seen: JSMap<Double>
  public var records: JSMap<SyncRecord>
  public var unknown = JSONObject()

  init(json: JSONValue) {
    device = json["device"]?.string ?? ""
    at = json["at"]?.number ?? .nan
    vv = numbers(json["vv"])
    seen = numbers(json["seen"])
    var records = JSMap<SyncRecord>()
    for (key, value) in json["records"]?.object ?? [:] { records[key] = SyncRecord(json: value) }
    self.records = records
    unknown = unknownKeys(json, ["v", "kind", "device", "at", "vv", "seen", "records"])
  }

  init(device: String, at: Double, vv: JSMap<Double>, seen: JSMap<Double>, records: JSMap<SyncRecord>) {
    self.device = device
    self.at = at
    self.vv = vv
    self.seen = seen
    self.records = records
  }

  var json: JSONValue {
    let known: JSONValue = [
      "v": 1, "kind": "snapshot", "device": .string(device), "at": .number(at), "vv": .object(vv.mapValues(JSONValue.number)),
      "seen": .object(seen.mapValues(JSONValue.number)), "records": .object(records.mapValues(\.json)),
    ]
    return withUnknown(known, unknown)
  }
}

func numbers(_ json: JSONValue?) -> JSMap<Double> {
  var out = JSMap<Double>()
  for (key, value) in json?.object ?? [:] { out[key] = value.number ?? .nan }
  return out
}

public struct FileMeta: Sendable, Equatable {
  public enum Kind: String, Sendable { case log, snapshot, bad }
  public var d: String
  public var k: Kind
  public var s: Double?
  public var vv: JSMap<Double>?
  public var at: Double
  public var unknown = JSONObject()

  init(d: String, k: Kind, s: Double? = nil, vv: JSMap<Double>? = nil, at: Double) {
    self.d = d
    self.k = k
    self.s = s
    self.vv = vv
    self.at = at
  }

  init(json: JSONValue) {
    d = json["d"]?.string ?? ""
    k = Kind(rawValue: json["k"]?.string ?? "") ?? .bad
    s = json["s"]?.number
    vv = json["vv"].map(numbers)
    at = json["at"]?.number ?? .nan
    unknown = unknownKeys(json, ["d", "k", "s", "vv", "at"])
  }

  var json: JSONValue {
    var out: JSONObject = ["d": .string(d), "k": .string(k.rawValue)]
    if let s { out["s"] = .number(s) }
    if let vv { out["vv"] = .object(vv.mapValues(JSONValue.number)) }
    out["at"] = .number(at)
    return withUnknown(.object(out), unknown)
  }
}

func unknownKeys(_ json: JSONValue, _ known: Set<String>) -> JSONObject {
  var out = JSONObject()
  for (key, value) in json.object ?? [:] where !known.contains(key) { out[key] = value }
  return out
}

func withUnknown(_ json: JSONValue, _ unknown: JSONObject) -> JSONValue {
  guard !unknown.isEmpty, var object = json.object else { return json }
  for (key, value) in unknown where !object.contains(key) { object[key] = value }
  return .object(object)
}

extension JSMap where Value == Double {
  subscript(device device: String) -> Double { self[device] ?? 0 }
}
