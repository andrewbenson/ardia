import Foundation
import SolaraModel

public struct LedgerValue: Sendable, Equatable {
  public var o: String
  public var u: String
  public var s: String

  public init(o: String, u: String, s: String) {
    self.o = o
    self.u = u
    self.s = s
  }

  public init?(json: JSONValue) {
    guard let o = json["o"]?.string, let u = json["u"]?.string, let s = json["s"]?.string else { return nil }
    self.init(o: o, u: u, s: s)
  }

  public var json: JSONValue { ["o": .string(o), "u": .string(u), "s": .string(s)] }
}

public struct LedgerEntry: Sendable, Equatable {
  public var d: [String]
  public var h: HLC?
  public var m: Double
  public var unknown = JSONObject()

  public init(d: [String], h: HLC?, m: Double) {
    self.d = d
    self.h = h
    self.m = m
  }

  public init(json: JSONValue) {
    d = json["d"]?.array?.compactMap(\.string) ?? []
    h = json["h"]?.string
    m = json["m"]?.number ?? 0
    for (key, value) in json.object ?? [:] where !["d", "h", "m"].contains(key) { unknown[key] = value }
  }

  public var json: JSONValue {
    var out: JSONObject = ["d": JSONValue(d), "h": h.map(JSONValue.string) ?? .null, "m": .number(m)]
    for (key, value) in unknown { out[key] = value }
    return .object(out)
  }
}

public struct Ledger: Sendable, Equatable {
  public var L: Double
  public var t: Double
  public var keys: JSMap<LedgerEntry>
  public var unknown = JSONObject()

  public init(L: Double, t: Double, keys: JSMap<LedgerEntry>) {
    self.L = L
    self.t = t
    self.keys = keys
  }

  public init(json: JSONValue) {
    L = json["L"]?.number ?? 0
    t = json["t"]?.number ?? 0
    var keys = JSMap<LedgerEntry>()
    for (key, value) in json["keys"]?.object ?? [:] { keys[key] = LedgerEntry(json: value) }
    self.keys = keys
    for (key, value) in json.object ?? [:] where !["v", "L", "t", "keys"].contains(key) { unknown[key] = value }
  }

  public var json: JSONValue {
    var out: JSONObject = ["v": 1, "L": .number(L), "t": .number(t), "keys": .object(keys.mapValues(\.json))]
    for (key, value) in unknown { out[key] = value }
    return .object(out)
  }
}

public enum LedgerDocument: Equatable {
  case newer
  case doc(JSONObject)
}

public func readLedgerDocument(_ text: String?) -> LedgerDocument {
  let empty: JSONObject = ["v": 1, "profiles": .object(JSONObject())]
  guard let text, let value = try? JSONValue.parse(text) else { return .doc(empty) }
  if let object = value.object, object.contains("v"), object["v"] != .number(1) { return .newer }
  guard let object = value.object, object["v"] == .number(1), jsTruthy(object["profiles"]) else { return .doc(empty) }
  return .doc(object)
}

public struct LocalLogin: Sendable, Equatable {
  public var value: LedgerValue
  public var modified: Double

  public init(value: LedgerValue, modified: Double) {
    self.value = value
    self.modified = modified
  }
}

public struct LedgerRecord: Sendable, Equatable {
  public var v: LedgerValue?
  public var h: HLC

  public init(v: LedgerValue?, h: HLC) {
    self.v = v
    self.h = h
  }
}

public struct Mark: Sendable, Equatable {
  public var L: Double
  public var t: Double

  public init(L: Double, t: Double) {
    self.L = L
    self.t = t
  }

  public var json: JSONValue { ["L": .number(L), "t": .number(t)] }
}

public struct Claim: Sendable, Equatable {
  public var key: String
  public var v: LedgerValue?
  public var at: Double
  public var afterRecord: HLC?

  public var json: JSONValue {
    ["key": .string(key), "v": v?.json ?? .null, "at": .number(at), "afterRecord": afterRecord.map(JSONValue.string) ?? .null]
  }
}

public struct Judgement: Sendable, Equatable {
  public enum Mode: String, Sendable { case consistent, rebuild, upgrade }
  public var mode: Mode
  public var claims: [Claim]
  public var apply: OrderedSet<String>
  public var seed: OrderedSet<String>
}

let digestsKept = 4

public func parseMark(_ value: String?) -> Mark? {
  let parts = (value ?? "").split(separator: "@", maxSplits: 2, omittingEmptySubsequences: false)
  guard parts.count == 2, let L = asciiDigits(parts[0]), let t = asciiDigits(parts[1]) else { return nil }
  return Mark(L: L, t: t)
}

func asciiDigits(_ text: Substring) -> Double? {
  guard !text.isEmpty, text.utf8.allSatisfy({ (48...57).contains($0) }) else { return nil }
  return Double(text)
}

public func formatMark(_ mark: Mark) -> String { "\(jsNumberText(mark.L))@\(jsNumberText(mark.t))" }

public func digestOf(_ value: LedgerValue?) -> String {
  guard let value else { return "" }
  let text = Array("\(value.o)\u{0}\(value.u)\u{0}\(value.s)".utf16)
  var h: UInt32 = 0x811c_9dc5
  for unit in text {
    h ^= UInt32(unit)
    h = h &* 0x0100_0193
  }
  return "\(text.count).\(String(h, radix: 36))"
}

public func judge(_ local: OrderedDict<String, LocalLogin>, _ mark: Mark?, _ ledger: Ledger?, _ records: OrderedDict<String, LedgerRecord>, _ now: Double) -> Judgement {
  var claims: [Claim] = []
  var apply = OrderedSet<String>()
  var seed = OrderedSet<String>()
  func recordDigest(_ key: String) -> String { digestOf(records[key]?.v) }
  let consistent = ledger != nil && mark != nil && mark!.L == ledger!.L && mark!.t == ledger!.t
  let mode: Judgement.Mode = consistent ? .consistent : ledger == nil && mark == nil ? .upgrade : .rebuild
  let after = mode == .rebuild ? jsMax(mark?.t ?? 0, ledger?.t ?? 0) : 0
  func claim(_ key: String, _ v: LedgerValue?, _ modified: Double) {
    let entry = ledger?.keys[key]
    let record = records[key]
    let agreed = entry != nil && recordDigest(key) == (entry!.d.first ?? "")
    claims.append(Claim(key: key, v: v, at: agreed ? jsMin(modified, now) : modified, afterRecord: agreed ? record?.h : nil))
  }
  var keys = OrderedSet<String>()
  for key in local.keys { keys.insert(key) }
  for key in records.keys { keys.insert(key) }
  for key in ledger?.keys.keys ?? [] { keys.insert(key) }
  for key in keys.elements {
    let here = local[key]
    let record = records[key]
    let entry = ledger?.keys[key]
    let mine = digestOf(here?.value)
    if here != nil, mine == recordDigest(key) {
      seed.insert(key)
      continue
    }
    if mode == .upgrade {
      guard let here else {
        if record?.v != nil { apply.insert(key) }
        continue
      }
      if let record {
        if here.modified > hlcWall(record.h) {
          claims.append(Claim(key: key, v: here.value, at: here.modified, afterRecord: nil))
        } else {
          apply.insert(key)
        }
      } else {
        claim(key, here.value, here.modified)
      }
      continue
    }
    if mode == .rebuild {
      if let here, here.modified > after {
        claim(key, here.value, here.modified)
      } else {
        seed.insert(key)
        if record != nil { apply.insert(key) }
      }
      continue
    }
    guard let here else {
      guard let entry else {
        if record?.v != nil { apply.insert(key) }
        continue
      }
      if recordDigest(key) == entry.d.first {
        claims.append(Claim(key: key, v: nil, at: now, afterRecord: record?.h))
      } else if record?.v != nil {
        apply.insert(key)
      }
      continue
    }
    guard let entry else {
      if record == nil || record!.v == nil {
        claims.append(Claim(key: key, v: here.value, at: jsMin(here.modified, now), afterRecord: record?.h))
      } else {
        claims.append(Claim(key: key, v: here.value, at: here.modified, afterRecord: nil))
      }
      continue
    }
    if mine == entry.d.first {
      if record != nil {
        apply.insert(key)
      } else if entry.h == nil {
        claims.append(Claim(key: key, v: here.value, at: jsMin(here.modified, now), afterRecord: nil))
      }
      continue
    }
    let older = entry.d.dropFirst().contains(mine)
    if older && here.modified <= entry.m {
      if record != nil { apply.insert(key) }
      continue
    }
    claim(key, here.value, here.modified)
  }
  return Judgement(mode: mode, claims: claims, apply: apply, seed: seed)
}

public func nextLedger(_ ledger: Ledger?, _ local: OrderedDict<String, LocalLogin>, _ records: OrderedDict<String, LedgerRecord>, _ mark: Mark, _ keys: [String]) -> Ledger {
  var out = Ledger(L: mark.L, t: mark.t, keys: ledger?.keys ?? JSMap())
  for key in keys {
    guard let here = local[key] else {
      out.keys.removeValue(forKey: key)
      continue
    }
    let digest = digestOf(here.value)
    let was = out.keys[key]?.d ?? []
    out.keys[key] = LedgerEntry(d: Array(([digest] + was.filter { $0 != digest }).prefix(digestsKept)), h: records[key]?.h, m: jsMin(here.modified, mark.t))
  }
  return out
}
