import Foundation
import SolaraModel
import SolaraSync
import Testing

final class ExtensionFolder: @unchecked Sendable {
  var files = OrderedDict<String, String>()
  var counter = 0
  var now: Double = 1_000_000
  var store = OrderedDict<String, (version: String, fingerprint: String)>()

  init() {
    store["a".repeated(32)] = ("1.0", "tabs")
    store["b".repeated(32)] = ("2.0", "storage")
    store["c".repeated(32)] = ("3.0", "all-hosts")
  }
}

extension String {
  func repeated(_ count: Int) -> String { String(repeating: self, count: count) }
}

struct InstalledEntry {
  var id: String
  var syncable: Bool?
  var version: String?
  var fingerprint: String?
  var approved: Bool?
  var userDisabled: Bool?
  var incognito: Bool?
  var pinned: Bool?

  mutating func assign(_ fields: JSONObject) {
    for (key, value) in fields {
      switch key {
      case "id": id = value.string ?? id
      case "syncable": syncable = value.bool
      case "version": version = value.string
      case "fingerprint": fingerprint = value.string
      case "approved": approved = value.bool
      case "userDisabled": userDisabled = value.bool
      case "incognito": incognito = value.bool
      case "pinned": pinned = value.bool
      default: break
      }
    }
  }

  var local: LocalExtension {
    LocalExtension(
      id: id, syncable: syncable ?? false, version: version, approved: approved, fingerprint: fingerprint, userDisabled: userDisabled, incognito: incognito,
      pinned: pinned)
  }

  var json: JSONValue {
    var out = JSONObject()
    out["id"] = .string(id)
    if let syncable { out["syncable"] = .bool(syncable) }
    if let version { out["version"] = .string(version) }
    if let fingerprint { out["fingerprint"] = .string(fingerprint) }
    if let approved { out["approved"] = .bool(approved) }
    if let userDisabled { out["userDisabled"] = .bool(userDisabled) }
    if let incognito { out["incognito"] = .bool(incognito) }
    if let pinned { out["pinned"] = .bool(pinned) }
    return .object(out)
  }
}

func changeJSON(_ change: ExtensionChange) -> JSONValue {
  switch change {
  case .cancel(let id): return ["kind": "cancel", "id": .string(id)]
  case .install(let id, let record, let approval), .reconcile(let id, let record, let approval):
    let kind: JSONValue = if case .install = change { "install" } else { "reconcile" }
    return ["kind": kind, "id": .string(id), "record": record.json, "approval": approval?.json ?? .null]
  }
}

final class FakeChrome: @unchecked Sendable {
  let folder: ExtensionFolder
  let mac: String
  let trace: Trace
  var installed = OrderedDict<String, InstalledEntry>()
  var pending = OrderedDict<String, ExtensionChange>()
  var intents = JSMap<ExtensionIntent>()
  var generation: Double = 0
  var ready = true
  var settling: [String] = []
  var queued: [String] = []
  var failing = false

  init(folder: ExtensionFolder, mac: String, trace: Trace) {
    self.folder = folder
    self.mac = mac
    self.trace = trace
  }

  func userInstall(_ id: String, _ extra: JSONObject) {
    let s = folder.store[id]!
    var entry = InstalledEntry(
      id: id, syncable: true, version: s.version, fingerprint: s.fingerprint, approved: true, userDisabled: false, incognito: false, pinned: false)
    entry.assign(extra)
    installed[id] = entry
    generation += 1
    intents[id] = ExtensionIntent(kind: .installed, g: generation)
  }

  func userUninstall(_ id: String) {
    installed[id] = nil
    generation += 1
    intents[id] = ExtensionIntent(kind: .uninstalled, g: generation)
  }

  func finishInstalls() {
    for (id, change) in pending {
      guard case .install(_, let record, let approval) = change else { continue }
      let s = folder.store[id]!
      let matches = approval.map { $0.v == s.version && $0.fps.contains(s.fingerprint) } ?? false
      installed[id] = InstalledEntry(
        id: id, syncable: true, version: s.version, fingerprint: s.fingerprint, approved: matches, userDisabled: !record.on, incognito: record.inc,
        pinned: record.pin)
    }
    pending = OrderedDict()
  }
}

final class FakeChromeHost: ExtensionsHost {
  let chrome: FakeChrome
  let nullRead: Bool

  init(_ chrome: FakeChrome, nullRead: Bool) {
    self.chrome = chrome
    self.nullRead = nullRead
  }

  func read() async throws -> LocalExtensions? {
    if nullRead { return nil }
    return LocalExtensions(
      ready: chrome.ready, extensions: chrome.installed.values.map(\.local), pending: chrome.pending.keys, settling: chrome.settling, queued: chrome.queued)
  }

  func change(_ change: ExtensionChange) async throws -> Bool {
    chrome.trace.push(["change": .string(chrome.mac), "value": changeJSON(change)])
    if chrome.failing { return false }
    switch change {
    case .cancel(let id):
      chrome.pending[id] = nil
      chrome.queued.removeAll { $0 == id }
    case .install(let id, _, _):
      chrome.pending[id] = change
    case .reconcile(let id, let record, let approval):
      var e = chrome.installed[id]!
      let grant = approval.map { $0.v == e.version && e.fingerprint.map($0.fps.contains) == true } ?? false
      e.userDisabled = !record.on
      e.incognito = record.inc
      e.pinned = record.pin
      e.approved = (e.approved ?? false) || grant
      chrome.installed[id] = e
    }
    return true
  }

  func intents() -> JSMap<ExtensionIntent> { chrome.intents }

  func settleIntents(_ published: JSMap<Double>) {
    for (id, g) in published where chrome.intents[id]?.g == g { chrome.intents.removeValue(forKey: id) }
  }

  func keepInstalled(_ id: String) {
    chrome.generation += 1
    chrome.intents[id] = ExtensionIntent(kind: .installed, g: chrome.generation)
  }
}

final class OtherAdapter: SyncAdapter {
  let prefix = "x:"
  let key: String

  init(device: String) { key = "x:\(device)" }

  func extract(_ context: ExtractContext) async throws -> Extraction? {
    let key = key
    return Extraction(values: [(key, 1)], ignore: { $0 != key })
  }

  func apply(_ visible: [(key: String, value: JSONValue)], _ changed: [String], _ base: (String) -> JSONValue?, _ records: ApplyRecords) async throws -> Bool? { true }
}

struct ExtensionTransport: SyncTransport, @unchecked Sendable {
  let folder: ExtensionFolder
  let mac: String
  let trace: Trace

  func write(_ scope: String, _ payload: String) async throws -> String {
    folder.counter += 1
    let id = "f\(folder.counter)"
    folder.files[id] = payload
    trace.push(["write": .string(mac), "id": .string(id), "payload": .string(payload)])
    return id
  }

  func read(_ scope: String, _ known: [String]) async throws -> Listing {
    let knownSet = Set(known)
    return Listing(
      files: folder.files.filter { !knownSet.contains($0.key) }.map { ($0.key, $0.value) }, pending: [], damaged: [], present: folder.files.keys)
  }

  func remove(_ scope: String, _ ids: [String]) async throws {
    trace.push(["remove": .string(mac), "ids": JSONValue(ids)])
    for id in ids { folder.files[id] = nil }
  }
}

final class Mac: @unchecked Sendable {
  let id: String
  let folder: ExtensionFolder
  let trace: Trace
  let chrome: FakeChrome
  var state = ScopeState()
  var clock: Clock!
  var adapter: ExtensionsAdapter
  var legacy = false
  var hold = false

  init(id: String, folder: ExtensionFolder, joining: Bool, trace: Trace) {
    self.id = id
    self.folder = folder
    self.trace = trace
    chrome = FakeChrome(folder: folder, mac: id, trace: trace)
    adapter = ExtensionsAdapter(host: FakeChromeHost(chrome, nullRead: false))
    clock = Clock(device: id, now: { [unowned folder] in folder.now })
    if joining { state.awaitRemote = true } else { state.joined = true }
  }

  var transport: ExtensionTransport { ExtensionTransport(folder: folder, mac: id, trace: trace) }

  func sync() async {
    folder.now += 10
    do {
      let adapters: [SyncAdapter] = legacy ? [OtherAdapter(device: id)] : [adapter, OtherAdapter(device: id)]
      let folder = folder
      let result = try await syncScope(scope: "p", state: state, transport: transport, adapters: adapters, clock: clock, device: id, now: { folder.now })
      if !legacy { try await adapter.reconcile(visible(state, "ext:"), folder.now) }
      trace.push(["sync": .string(id), "result": resultJSON(result)])
    } catch {
      trace.push(["sync": .string(id), "error": .string("\(error)")])
    }
    if !hold { chrome.finishInstalls() }
  }

  func record() -> JSONValue {
    var intents = JSONObject()
    for (id, intent) in chrome.intents { intents[id] = ["kind": .string(intent.kind.rawValue), "g": .number(intent.g)] }
    return [
      "mac": .string(id), "state": .string(syncCanonical(state.json)), "installed": .string(syncCanonical(.array(chrome.installed.values.map(\.json)))),
      "pending": JSONValue(chrome.pending.keys), "queued": JSONValue(chrome.queued), "intents": .object(intents), "clock": .string(clock.last),
    ]
  }
}

func runExtensionScenario(_ script: JSONValue) async throws -> [JSONValue] {
  let trace = Trace()
  let folder = ExtensionFolder()
  var macs = OrderedDict<String, Mac>()
  for (id, joining) in script["macs"]?.object ?? [:] { macs[id] = Mac(id: id, folder: folder, joining: joining.truthy, trace: trace) }
  for step in script["steps"]?.array ?? [] {
    let m = step["mac"]?.string.flatMap { macs[$0] }
    let id = step["id"]?.string ?? ""
    switch step["op"]?.string ?? "" {
    case "install": m!.chrome.userInstall(id, step["extra"]?.object ?? [:])
    case "uninstall": m!.chrome.userUninstall(id)
    case "edit": m!.chrome.installed[id]?.assign(step["fields"]?.object ?? [:])
    case "put":
      var entry = InstalledEntry(id: id)
      entry.assign(step["entry"]?.object ?? [:])
      m!.chrome.installed[id] = entry
    case "clearIntents": m!.chrome.intents = JSMap()
    case "store": folder.store[id] = (step["version"]?.string ?? "", step["fingerprint"]?.string ?? "")
    case "chrome":
      let value = step["value"] ?? .null
      switch step["field"]?.string ?? "" {
      case "ready": m!.chrome.ready = value.truthy
      case "failing": m!.chrome.failing = value.truthy
      case "settling": m!.chrome.settling = value.array?.compactMap(\.string) ?? []
      case "queued": m!.chrome.queued = value.array?.compactMap(\.string) ?? []
      default: throw TransportError(description: "unknown chrome field")
      }
    case "hold": m!.hold = step["value"]?.truthy ?? false
    case "finish": m!.chrome.finishInstalls()
    case "clearPending": m!.chrome.pending = OrderedDict()
    case "adapter": m!.adapter = ExtensionsAdapter(host: FakeChromeHost(m!.chrome, nullRead: step["nullRead"]?.truthy ?? false))
    case "legacy": m!.legacy = step["value"]?.truthy ?? false
    case "nullRecord":
      let mac = m!
      let key = extensionKey(id)
      let h = mac.clock.tick()
      mac.state.records[key] = SyncRecord(h: h, v: .null, o: Origin(mac.id, mac.state.seq + 1))
      mac.state.outbox.append(Op(k: key, h: h, v: .null))
    case "compact":
      let mac = m!
      var options = ScopeOptions()
      options.pruneGrace = 0
      do {
        let result = try await compact(mac.state, mac.transport, "p", mac.id, folder.now, options, force: true)
        trace.push(["compact": .string(mac.id), "result": .bool(result)])
      } catch {
        trace.push(["compact": .string(mac.id), "error": .string("\(error)")])
      }
    case "advance": folder.now += step["ms"]?.number ?? 0
    case "sync": await m!.sync()
    default: throw TransportError(description: "unknown step")
    }
    trace.push(["step": step["op"] ?? .null, "macs": .array(macs.values.map { $0.record() })])
  }
  return trace.entries
}

@Suite struct ExtensionScenarioTests {
  @Test func everyExtensionScenarioTracesAsTheTypeScriptAdapterDoes() async throws {
    let cases = try Scenarios.load("extensions")
    #expect(!cases.isEmpty)
    var bad = 0
    for item in cases {
      let got = try await runExtensionScenario(item["script"] ?? .null)
      let name = item["script"]?["name"]?.string ?? "?"
      if let diff = Scenarios.firstDifference(item["trace"]?.array ?? [], got) {
        bad += 1
        if bad <= 5 { Issue.record("\(name): entry \(diff.at) differs\n  ts:    \(diff.ts.prefix(1500))\n  swift: \(diff.swift.prefix(1500))") }
      }
    }
    #expect(bad == 0, "\(bad) of \(cases.count) scenarios differ")
  }

  @Test func versionsCompareAsChromeOrdersThem() {
    #expect(compareVersions("1.10", "1.9") == 1)
    #expect(compareVersions("1.0", "1") == 0)
    #expect(compareVersions("2", "10") == -1)
    #expect(compareVersions("x.1", "0.1") == 0)
    #expect(compareVersions(" 3a", "3") == 0)
  }
}
