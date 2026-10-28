import Foundation
import SolaraModel
import SolaraSync
import Testing

struct TransportError: Error, CustomStringConvertible {
  let description: String
}

final class Folder: @unchecked Sendable {
  struct Entry {
    var payload: String
    var hiddenFrom: Set<String> = []
    var partialFor: Set<String> = []
  }
  var scopes: [String: OrderedDict<String, Entry>] = [:]
  var counter = 0
  var now: Double = 0
}

final class Device: @unchecked Sendable {
  let id: String
  let folder: Folder
  let options: JSONObject
  let trace: Trace
  var store = OrderedDict<String, JSONValue>()
  var settings = OrderedDict<String, JSONValue>()
  var state = ScopeState()
  var offset: Double = 0
  var saved = ScopeState().json.text()
  var savedClock: String? = nil
  var journal = OrderedDict<Double, LogFile>()
  var onRead: [JSONValue]? = nil
  var failWrite: String? = nil
  var clock: Clock!
  var ledger = OrderedDict<String, JSONValue>()
  var stamps = OrderedDict<String, Stamped>()
  var removes = OrderedSet<String>()
  var reapplies = OrderedSet<String>()
  var refused = Set<JSKey>()
  var redesign: Bool { options["redesign"]?.truthy ?? false }

  init(id: String, folder: Folder, options: JSONObject, trace: Trace) {
    self.id = id
    self.folder = folder
    self.options = options
    self.trace = trace
    clock = Clock(device: id, now: { [unowned self] in self.time() })
  }

  func time() -> Double { folder.now + offset }

  func adapters() -> [SyncAdapter] {
    [MapAdapter(device: self, prefix: "x:", settings: false), MapAdapter(device: self, prefix: "set:", settings: true)]
      + (redesign ? [LedgerAdapter(device: self)] : [])
  }

  func scopeOptions() -> ScopeOptions {
    var o = ScopeOptions()
    o.pruneGrace = options["pruneGrace"]?.number ?? 0
    if let v = options["tombstoneTTL"]?.number { o.tombstoneTTL = v }
    if let v = options["compactAfterFiles"]?.number { o.compactAfterFiles = v }
    if let v = options["compactInterval"]?.number { o.compactInterval = v }
    if let v = options["damagedGiveUp"]?.number { o.damagedGiveUp = v }
    o.persist = { [unowned self] batches in
      for f in batches { self.journal[f.seq] = LogFile(json: try JSONValue.parse(f.json.text())) }
    }
    if redesign {
      o.writtenKeysOnly = true
      o.beforeApply = { [unowned self] keys in self.trace.push(["beforeApply": .string(self.id), "keys": JSONValue(keys)]) }
      o.extracted = { [unowned self] prefix, keys, ignore in
        self.trace.push(["extracted": .string(self.id), "prefix": .string(prefix), "keys": JSONValue(keys), "ignored": JSONValue(keys.filter(ignore))])
      }
    }
    return o
  }

  func record() -> JSONValue {
    func sorted(_ map: OrderedDict<String, JSONValue>) -> JSONValue {
      var out = JSONObject()
      for key in map.keys.sorted(by: jsKeyPrecedes) { out[key] = map[key]! }
      return .object(out)
    }
    var out: JSONObject = ["device": .string(id), "state": .string(syncCanonical(state.json)), "store": sorted(store), "settings": sorted(settings), "clock": .string(clock.last)]
    if redesign { out["ledger"] = sorted(ledger) }
    return .object(out)
  }

  func ledgerStep(_ step: JSONValue) -> Bool {
    let key = step["key"]?.string ?? ""
    switch step["op"]?.string ?? "" {
    case "ySet": ledger[key] = step["value"] ?? .null
    case "yDelete": ledger[key] = nil
    case "stamp": stamps[key] = Stamped(at: step["at"]?.number ?? 0, after: step["after"]?.string)
    case "remove": _ = removes.insert(key)
    case "reapply": _ = reapplies.insert(key)
    case "refuse": refused.insert(JSKey(key))
    default: return false
    }
    return true
  }
}

final class LedgerAdapter: SyncAdapter {
  unowned let device: Device
  let prefix = "y:"
  var publishOnlyAfterPull: Bool { true }
  var ownsItsChanges: Bool { true }

  init(device: Device) { self.device = device }

  func extract(_ context: ExtractContext) async throws -> Extraction? {
    device.trace.push(["extract": .string(device.id), "prefix": "y:", "downloading": .bool(context.downloading())])
    let stamps = device.stamps
    let remove = device.removes.elements
    let reapply = device.reapplies.elements
    device.stamps = OrderedDict()
    device.removes = OrderedSet()
    device.reapplies = OrderedSet()
    return Extraction(
      values: device.ledger.map { ($0.key, $0.value) }, ignore: { $0 == "y:3" }, stamp: { stamps[$0] }, remove: remove, reapply: reapply)
  }

  func apply(_ visible: [(key: String, value: JSONValue)], _ changed: [String], _ base: (String) -> JSONValue?, _ records: ApplyRecords) async throws -> Bool? {
    nil
  }

  func applyKeys(_ visible: [(key: String, value: JSONValue)], _ changed: [String], _ base: (String) -> JSONValue?, _ records: ApplyRecords) async throws
    -> ApplyOutcome
  {
    var shown = JSONObject()
    for (key, value) in visible { shown[key] = value }
    device.trace.push(["apply": .string(device.id), "prefix": "y:", "changed": JSONValue(changed), "visible": .object(shown)])
    var written: [String] = []
    for key in changed where !device.refused.contains(JSKey(key)) {
      device.ledger[key] = shown[key]
      written.append(key)
    }
    device.refused = []
    return .written(written)
  }
}

final class Trace: @unchecked Sendable {
  var entries: [JSONValue] = []
  func push(_ entry: JSONValue) { entries.append(entry) }
}

final class MapAdapter: SyncAdapter {
  unowned let device: Device
  let prefix: String
  let settings: Bool
  var adoptRemoteOnJoin: Bool { settings }

  init(device: Device, prefix: String, settings: Bool) {
    self.device = device
    self.prefix = prefix
    self.settings = settings
  }

  func extract(_ context: ExtractContext) async throws -> Extraction? {
    let map = settings ? device.settings : device.store
    return Extraction(values: map.map { ($0.key, $0.value) })
  }

  func apply(_ visible: [(key: String, value: JSONValue)], _ changed: [String], _ base: (String) -> JSONValue?, _ records: ApplyRecords) async throws -> Bool? {
    var shown = JSONObject()
    for (key, value) in visible { shown[key] = value }
    device.trace.push(["apply": .string(device.id), "prefix": .string(prefix), "changed": JSONValue(changed), "visible": .object(shown)])
    for key in changed {
      if settings {
        if let value = shown[key] { device.settings[key] = value }
      } else {
        device.store[key] = shown[key]
      }
    }
    return nil
  }
}

struct DeviceTransport: SyncTransport, @unchecked Sendable {
  let device: Device
  let run: (JSONValue) async throws -> Void

  func write(_ scope: String, _ payload: String) async throws -> String {
    let fail = device.failWrite
    device.failWrite = nil
    if fail == "before" { throw TransportError(description: "offline") }
    device.folder.counter += 1
    let id = "f\(device.folder.counter)"
    device.folder.scopes[scope, default: OrderedDict()][id] = Folder.Entry(payload: payload)
    device.trace.push(["write": .string(device.id), "id": .string(id), "payload": .string(payload)])
    if fail == "after" { throw TransportError(description: "timed out") }
    return id
  }

  func read(_ scope: String, _ known: [String]) async throws -> Listing {
    var listing = Listing(files: [], pending: [], damaged: [], present: [])
    let knownSet = Set(known)
    for (id, e) in device.folder.scopes[scope] ?? OrderedDict() {
      listing.present.append(id)
      if knownSet.contains(id) { continue }
      if e.hiddenFrom.contains(device.id) {
        listing.pending.append(id)
      } else if e.partialFor.contains(device.id) {
        listing.damaged.append((id, 0))
      } else {
        listing.files.append((id, e.payload))
      }
    }
    let hook = device.onRead
    device.onRead = nil
    for step in hook ?? [] { try await run(step) }
    return listing
  }

  func remove(_ scope: String, _ ids: [String]) async throws {
    device.trace.push(["remove": .string(device.id), "ids": JSONValue(ids)])
    for id in ids { device.folder.scopes[scope]?[id] = nil }
  }
}

func resultJSON(_ r: CycleResult) -> JSONValue {
  ["published": .number(Double(r.published)), "changed": .number(Double(r.changed)), "pending": .number(r.pending), "compacted": .bool(r.compacted)]
}

func runScenario(_ script: JSONValue) async throws -> [JSONValue] {
  let trace = Trace()
  let folder = Folder()
  var devices = OrderedDict<String, Device>()
  for (id, options) in script["devices"]?.object ?? [:] { devices[id] = Device(id: id, folder: folder, options: options.object ?? [:], trace: trace) }
  let scope = script["scope"]?.string ?? "s"
  func latest() -> String? { folder.scopes[scope]?.keys.last }
  func run(_ step: JSONValue) async throws {
    let d = step["device"]?.string.flatMap { devices[$0] }
    func file() -> String? {
      let f = step["file"]?.string
      return f == "latest" ? latest() : f
    }
    switch step["op"]?.string ?? "" {
    case "time": folder.now = step["now"]?.number ?? 0
    case "advance": folder.now += step["ms"]?.number ?? 0
    case "offset": d!.offset = step["ms"]?.number ?? 0
    case "set":
      let key = step["key"]?.string ?? ""
      if key.hasPrefix("set:") { d!.settings[key] = step["value"] ?? .null } else { d!.store[key] = step["value"] ?? .null }
    case "delete":
      let key = step["key"]?.string ?? ""
      if key.hasPrefix("set:") { d!.settings[key] = nil } else { d!.store[key] = nil }
    case "awaitRemote": d!.state.awaitRemote = true
    case "ySet", "yDelete", "stamp", "remove", "reapply", "refuse": _ = d!.ledgerStep(step)
    case "onRead": d!.onRead = step["steps"]?.array ?? []
    case "failWrite": d!.failWrite = step["when"]?.string
    case "hide", "unhide", "partial", "whole":
      guard let id = file(), var e = folder.scopes[scope]?[id] else { break }
      let op = step["op"]!.string!
      let device = d!.id
      switch op {
      case "hide": e.hiddenFrom.insert(device)
      case "unhide": e.hiddenFrom.remove(device)
      case "partial": e.partialFor.insert(device)
      default: e.partialFor.remove(device)
      }
      folder.scopes[scope]![id] = e
    case "drop":
      if let id = file() { folder.scopes[scope]?[id] = nil }
    case "sync":
      let device = d!
      do {
        let result = try await syncScope(
          scope: scope, state: device.state, transport: DeviceTransport(device: device, run: run), adapters: device.adapters(), clock: device.clock,
          device: device.id, now: { device.time() }, options: device.scopeOptions())
        trace.push(["sync": .string(device.id), "result": resultJSON(result)])
      } catch {
        trace.push(["sync": .string(device.id), "error": .string("\(error)")])
      }
    case "compact":
      let device = d!
      do {
        let result = try await compact(
          device.state, DeviceTransport(device: device, run: run), scope, device.id, device.time(), device.scopeOptions(), force: step["force"]?.truthy ?? false)
        trace.push(["compact": .string(device.id), "result": .bool(result)])
      } catch {
        trace.push(["compact": .string(device.id), "error": .string("\(error)")])
      }
    case "relaunch":
      let device = d!
      device.state = ScopeState(json: try JSONValue.parse(device.state.json.text()))
      device.clock = Clock(device: device.id, last: device.clock.last, now: { device.time() })
    case "save":
      let device = d!
      device.saved = device.state.json.text()
      device.savedClock = device.clock.last
      for seq in device.journal.keys where seq <= device.state.seq { device.journal[seq] = nil }
    case "crash":
      let device = d!
      device.state = ScopeState(json: try JSONValue.parse(device.saved))
      device.clock = Clock(device: device.id, last: device.savedClock, now: { device.time() })
      restoreJournal(device.state, device.journal.values, device.clock)
    default:
      throw TransportError(description: "unknown step")
    }
  }
  for step in script["steps"]?.array ?? [] {
    try await run(step)
    trace.push(["step": step["op"] ?? .null, "devices": .array(devices.values.map { $0.record() })])
  }
  return trace.entries
}

enum Scenarios {
  static let folder = ProcessInfo.processInfo.environment["SCENARIO_DIR"].map { URL(fileURLWithPath: $0) }
    ?? URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "Scenarios")

  static func load(_ name: String) throws -> [JSONValue] {
    let url = folder.appending(path: "\(name).json.deflate")
    let data = try (Data(contentsOf: url) as NSData).decompressed(using: .zlib) as Data
    return try JSONValue.parse(data)["cases"]?.array ?? []
  }

  static func firstDifference(_ expected: [JSONValue], _ got: [JSONValue]) -> (at: Int, ts: String, swift: String)? {
    let firstDiff = (0..<min(expected.count, got.count)).first { expected[$0].text() != got[$0].text() }
    guard let at = firstDiff ?? (expected.count != got.count ? min(expected.count, got.count) : nil) else { return nil }
    let ts = at < expected.count ? Array(expected[at].text().utf16) : []
    let swift = at < got.count ? Array(got[at].text().utf16) : []
    let char = (0..<min(ts.count, swift.count)).first { ts[$0] != swift[$0] } ?? min(ts.count, swift.count)
    let window = { (units: [UInt16]) in String(decoding: units[max(0, char - 300)..<min(units.count, char + 300)], as: UTF16.self) }
    return (at, at < expected.count ? window(ts) : "nothing", at < got.count ? window(swift) : "nothing")
  }
}

@Suite struct ScenarioTests {
  @Test(arguments: ["scope", "scope-redesign"]) func everyScenarioTracesAsTheTypeScriptMergeDoes(_ file: String) async throws {
    let cases = try Scenarios.load(file)
    #expect(!cases.isEmpty)
    var bad = 0
    for item in cases {
      let got = try await runScenario(item["script"] ?? .null)
      let name = item["script"]?["name"]?.string ?? "?"
      if let diff = Scenarios.firstDifference(item["trace"]?.array ?? [], got) {
        bad += 1
        if bad <= 5 { Issue.record("\(name): entry \(diff.at) differs\n  ts:    \(diff.ts.prefix(900))\n  swift: \(diff.swift.prefix(900))") }
      }
    }
    #expect(bad == 0, "\(bad) of \(cases.count) scenarios differ")
  }
}
