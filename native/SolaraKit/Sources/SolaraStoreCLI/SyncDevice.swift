import Foundation
import SolaraModel
import SolaraSync

struct LineChannel: @unchecked Sendable {
  func send(_ value: JSONValue) {
    print(value.text())
    fflush(stdout)
  }

  func receive() throws -> JSONValue {
    guard let line = readLine(strippingNewline: true) else { throw SyncError(description: "the driver closed the channel") }
    return try JSONValue.parse(line)
  }
}

final class ChannelDevice: @unchecked Sendable {
  let id: String
  let channel = LineChannel()
  var options: JSONObject
  var store = OrderedDict<String, JSONValue>()
  var settings = OrderedDict<String, JSONValue>()
  var state = ScopeState()
  var now: Double = 0
  var offset: Double = 0
  var saved = ScopeState().json.text()
  var savedClock: String? = nil
  var journal = OrderedDict<Double, LogFile>()
  var clock: Clock!

  init(id: String, options: JSONObject) {
    self.id = id
    self.options = options
    clock = Clock(device: id, now: { [unowned self] in self.now + self.offset })
  }

  func time() -> Double { now + offset }

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
    return o
  }

  func record() -> JSONValue {
    func sorted(_ map: OrderedDict<String, JSONValue>) -> JSONValue {
      var out = JSONObject()
      for key in map.keys.sorted(by: jsKeyPrecedes) { out[key] = map[key]! }
      return .object(out)
    }
    return ["device": .string(id), "state": .string(syncCanonical(state.json)), "store": sorted(store), "settings": sorted(settings), "clock": .string(clock.last)]
  }

  func local(_ step: JSONValue) {
    let key = step["key"]?.string ?? ""
    switch step["op"]?.string ?? "" {
    case "set": if key.hasPrefix("set:") { settings[key] = step["value"] ?? .null } else { store[key] = step["value"] ?? .null }
    case "delete": if key.hasPrefix("set:") { settings[key] = nil } else { store[key] = nil }
    default: break
    }
  }

  func serve() async {
    while let request = try? channel.receive() {
      now = request["now"]?.number ?? now
      switch request["op"]?.string ?? "" {
      case "offset": offset = request["ms"]?.number ?? 0
      case "set", "delete": local(request)
      case "awaitRemote": state.awaitRemote = true
      case "sync":
        do {
          let r = try await syncScope(
            scope: request["scope"]?.string ?? "s", state: state, transport: ChannelTransport(device: self), adapters: adapters(), clock: clock, device: id,
            now: { [unowned self] in self.time() }, options: scopeOptions())
          channel.send(["done": ["published": .number(Double(r.published)), "changed": .number(Double(r.changed)), "pending": .number(r.pending), "compacted": .bool(r.compacted)]])
          continue
        } catch {
          channel.send(["failed": .string("\(error)")])
          continue
        }
      case "compact":
        do {
          let r = try await compact(state, ChannelTransport(device: self), request["scope"]?.string ?? "s", id, time(), scopeOptions(), force: request["force"]?.truthy ?? false)
          channel.send(["done": .bool(r)])
        } catch {
          channel.send(["failed": .string("\(error)")])
        }
        continue
      case "relaunch":
        state = ScopeState(json: (try? JSONValue.parse(state.json.text())) ?? .null)
        clock = Clock(device: id, last: clock.last, now: { [unowned self] in self.time() })
      case "save":
        saved = state.json.text()
        savedClock = clock.last
        for seq in journal.keys where seq <= state.seq { journal[seq] = nil }
      case "crash":
        state = ScopeState(json: (try? JSONValue.parse(saved)) ?? .null)
        clock = Clock(device: id, last: savedClock, now: { [unowned self] in self.time() })
        restoreJournal(state, journal.values, clock)
      default: break
      }
      channel.send(["record": record()])
    }
  }

  func adapters() -> [SyncAdapter] {
    [ChannelAdapter(device: self, prefix: "x:", settings: false), ChannelAdapter(device: self, prefix: "set:", settings: true)]
  }
}

final class ChannelAdapter: SyncAdapter {
  unowned let device: ChannelDevice
  let prefix: String
  let settings: Bool
  var adoptRemoteOnJoin: Bool { settings }

  init(device: ChannelDevice, prefix: String, settings: Bool) {
    self.device = device
    self.prefix = prefix
    self.settings = settings
  }

  func extract(_ context: ExtractContext) async throws -> Extraction? {
    Extraction(values: (settings ? device.settings : device.store).map { ($0.key, $0.value) })
  }

  func apply(_ visible: [(key: String, value: JSONValue)], _ changed: [String], _ base: (String) -> JSONValue?, _ records: ApplyRecords) async throws -> Bool? {
    var shown = JSONObject()
    for (key, value) in visible { shown[key] = value }
    device.channel.send(["call": "apply", "prefix": .string(prefix), "changed": JSONValue(changed), "visible": .object(shown)])
    _ = try device.channel.receive()
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

struct ChannelTransport: SyncTransport, @unchecked Sendable {
  let device: ChannelDevice

  func write(_ scope: String, _ payload: String) async throws -> String {
    device.channel.send(["call": "write", "scope": .string(scope), "payload": .string(payload)])
    let reply = try device.channel.receive()
    if let error = reply["error"]?.string { throw SyncError(description: error) }
    return reply["id"]?.string ?? ""
  }

  func read(_ scope: String, _ known: [String]) async throws -> Listing {
    device.channel.send(["call": "read", "scope": .string(scope), "known": JSONValue(known)])
    let reply = try device.channel.receive()
    for step in reply["then"]?.array ?? [] { device.local(step) }
    let listing = reply["listing"] ?? .null
    return Listing(
      files: (listing["files"]?.array ?? []).map { ($0["id"]?.string ?? "", $0["payload"]?.string ?? "") },
      pending: listing["pending"]?.array?.compactMap(\.string) ?? [],
      damaged: (listing["damaged"]?.array ?? []).map { ($0["id"]?.string ?? "", $0["age"]?.number ?? 0) },
      present: listing["present"]?.array?.compactMap(\.string) ?? [])
  }

  func remove(_ scope: String, _ ids: [String]) async throws {
    device.channel.send(["call": "remove", "scope": .string(scope), "ids": JSONValue(ids)])
    _ = try device.channel.receive()
  }
}
