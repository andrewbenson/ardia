import Foundation
import SolaraModel

public let journalDocName = "sync-edits.json"
public let genDocName = "sync-edits.gen"

public protocol JournalDisk: AnyObject {
  func read(_ name: String) -> String?
  func write(_ name: String, _ text: String)
}

public struct InStep: Sendable, Equatable {
  public var T: JSONValue?
  public var vv: JSONValue

  public var json: JSONValue {
    var out = JSONObject()
    if let T { out["T"] = T }
    out["vv"] = vv
    return .object(out)
  }
}

public enum JournalFallback: String, Sendable { case none, union, nothing }

enum ParsedDoc {
  case missing
  case unreadable
  case doc(JSONObject)
}

func parseDoc(_ text: String?, _ valid: (JSONObject) -> Bool) -> ParsedDoc {
  guard let text else { return .missing }
  guard let value = try? JSONValue.parse(text), case .object(let object) = value, valid(object) else { return .unreadable }
  return .doc(object)
}

func isJournalDoc(_ doc: JSONObject) -> Bool {
  doc["v"] == .number(1) && doc["g"]?.number != nil && doc["entries"]?.object != nil
}

func isGenDoc(_ doc: JSONObject) -> Bool {
  doc["v"] == .number(1) && doc["g"]?.number != nil
}

func jsTruthy(_ value: JSONValue?) -> Bool {
  guard let value else { return false }
  switch value {
  case .null: return false
  case .bool(let b): return b
  case .number(let n): return n != 0 && !n.isNaN
  case .string(let s): return !s.isEmpty
  default: return true
  }
}

public final class EditJournal {
  let disk: JournalDisk
  var doc: JSONObject
  var T: JSONValue
  var vv: JSONValue
  var floorT: Double
  var anchorT: Double
  public let lost: Bool
  public let fallback: JournalFallback
  public let inStep: InStep?

  public init(disk: JournalDisk, storeG: Double, storeT: Double = 0) {
    self.disk = disk
    let saved = parseDoc(disk.read(journalDocName), isJournalDoc)
    let gen = parseDoc(disk.read(genDocName), isGenDoc)
    let genDoc: JSONObject? = if case .doc(let d) = gen { d } else { nil }
    let genT = genDoc?["T"]
    let inStep: InStep? =
      if let genDoc, genT != .null, jsTruthy(genDoc["vv"]) { InStep(T: genT, vv: genDoc["vv"]!) } else { nil }
    let readable: JSONObject? = if case .doc(let d) = saved { d } else { nil }
    let savedMissing = if case .missing = saved { true } else { false }
    let fresh = savedMissing && genDoc == nil && storeG == 0
    let genG = genDoc?["g"]?.number ?? 0
    let readableG = readable?["g"]?.number ?? 0
    let lostJournal = !fresh && (readable == nil || readableG < genG || readableG < storeG)
    doc = lostJournal || readable == nil ? ["v": 1, "g": .number(jsMax(storeG, genG)), "newest": .null, "entries": .object(JSONObject())] : readable!
    T = (genT == nil || genT == .null) ? .null : genT!
    vv = (genDoc?["vv"] == nil || genDoc?["vv"] == .null) ? .null : genDoc!["vv"]!
    floorT = jsMax(T.number ?? 0, storeT)
    anchorT = storeT
    lost = lostJournal
    let union: Bool = if let inStep, let t = inStep.T?.number { storeT >= t } else { false }
    fallback = !lostJournal ? .none : inStep != nil && union ? .union : .nothing
    self.inStep = inStep
    if !lostJournal, readable != nil, genDoc == nil || genDoc!["g"]?.number != doc["g"]?.number { writeGen() }
  }

  public var g: Double { doc["g"]?.number ?? 0 }
  public var lastInStepT: Double { anchorT }

  func writeGen() {
    let gen: JSONObject = ["v": 1, "g": doc["g"] ?? .null, "T": T, "vv": vv]
    disk.write(genDocName, JSONValue.object(gen).text())
  }

  func writeJournal() {
    disk.write(journalDocName, JSONValue.object(doc).text())
    writeGen()
  }

  var entriesObject: JSONObject {
    get { doc["entries"]?.object ?? JSONObject() }
    set { doc["entries"] = .object(newValue) }
  }

  public func entry(_ scope: String, _ key: String) -> JSONValue? { entriesObject[scope]?.object?[key] }

  public func entries(_ scope: String) -> [(key: String, value: JSONValue)] {
    (entriesObject[scope]?.object ?? JSONObject()).map { ($0.key, $0.value) }
  }

  public func record(_ scope: String, _ key: String, _ entry: JSONValue) {
    doc["g"] = .number(g + 1)
    var entries = entriesObject
    var inScope = entries[scope]?.object ?? JSONObject()
    inScope[key] = entry
    entries[scope] = .object(inScope)
    entriesObject = entries
    let h = entry["h"]?.string ?? ""
    let newest = doc["newest"]?.string
    if newest == nil || newest!.isEmpty || jsKeyPrecedes(newest!, h) { doc["newest"] = .string(h) }
    writeJournal()
  }

  public func clear(_ scope: String, _ key: String, _ h: String) {
    var entries = entriesObject
    guard var inScope = entries[scope]?.object, inScope[key]?["h"] == .string(h) else { return }
    inScope.removeValue(forKey: key)
    if inScope.isEmpty { entries.removeValue(forKey: scope) } else { entries[scope] = .object(inScope) }
    entriesObject = entries
    doc["g"] = .number(g + 1)
    writeJournal()
  }

  public func inStepAt(_ at: Double, _ vectors: JSONValue) {
    let next = jsMax(at, floorT + 1)
    T = .number(next)
    floorT = next
    anchorT = next
    vv = vectors
    writeGen()
  }
}

public func unionFallback(
  scope: String, T: Double, vvT: JSONValue, local: [(key: String, value: JSONValue)], records: OrderedDict<String, (v: JSONValue, o: Origin)>,
  everSeen: [String], tombstoned: [String]
) -> (publish: [(key: String, v: JSONValue, at: Double)], apply: OrderedSet<String>, publishDeletions: Bool) {
  var publish = OrderedDict<String, (v: JSONValue, at: Double)>()
  var apply = OrderedSet<String>()
  func covered(_ o: Origin) -> Bool { (vvT[scope]?[o.device]?.number ?? 0) >= o.seq }
  let everSeen = Set(everSeen.map(JSKey.init))
  let tombstoned = Set(tombstoned.map(JSKey.init))
  for (key, value) in local {
    if let record = records[key] {
      if record.v.text() == value.text() { continue }
      if covered(record.o) { publish[key] = (value, T) } else { apply.insert(key) }
    } else if everSeen.contains(JSKey(key)) || tombstoned.contains(JSKey(key)) {
      apply.insert(key)
    } else {
      publish[key] = (value, T)
    }
  }
  return (publish.map { ($0.key, $0.value.v, $0.value.at) }, apply, false)
}
