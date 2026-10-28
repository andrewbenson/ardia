import Foundation
import SolaraModel
import SolaraSync
import Synchronization
import Testing

final class LedgerGate: Sendable {
  let reached = AsyncStream<Void>.makeStream()
  let opened = AsyncStream<Void>.makeStream()

  func pass() async {
    reached.continuation.yield()
    for await _ in opened.stream { return }
  }

  func waitReached() async {
    for await _ in reached.stream { return }
  }

  func open() {
    opened.continuation.yield()
    opened.continuation.finish()
  }
}

struct LedgerHostState: Sendable {
  var logins = OrderedDict<String, LocalLogin>()
  var mark: String? = nil
  var doc: String? = nil
  var unopened = OrderedSet<String>()
  var failCheck = false
  var calls: [String] = []
  var gates: [String: LedgerGate] = [:]
}

final class LedgerTestHost: LedgerPasswordsHost {
  let state = Mutex(LedgerHostState())

  static func key(_ o: String, _ u: String) -> String { "pw:\(o)\n\(u)" }

  func gate(_ name: String) -> LedgerGate {
    let gate = LedgerGate()
    state.withLock { $0.gates[name] = gate }
    return gate
  }

  func count(_ name: String) -> Int { state.withLock { $0.calls.filter { $0 == name }.count } }

  func passGate(_ name: String) async {
    let gate = state.withLock { s -> LedgerGate? in
      s.calls.append(name)
      let n = s.calls.filter { $0 == name }.count
      return s.gates.removeValue(forKey: "\(name)#\(n)") ?? s.gates.removeValue(forKey: name)
    }
    await gate?.pass()
  }

  var ledger: JSONValue? { state.withLock { $0.doc }.flatMap { try? JSONValue.parse($0) } }

  func engineProfile(_ profileId: String) -> String { profileId }

  func readMarked(_ engineProfile: String) async throws -> JSONValue? {
    await passGate("readMarked")
    return state.withLock { s in
      let logins = s.logins.values.map { l -> JSONValue in
        ["origin": .string(l.value.o), "username": .string(l.value.u), "s": .string(l.value.s), "modified": .number(l.modified), "created": .number(l.modified)]
      }
      return ["logins": .array(logins), "mark": s.mark.map(JSONValue.string) ?? .null]
    }
  }

  func checkSealed(_ values: [LedgerValue]) async throws -> [JSONValue] {
    await passGate("checkSealed")
    return try state.withLock { s in
      if s.failCheck { throw SyncError(description: "check failed") }
      return values.map { .bool(!s.unopened.contains(Self.key($0.o, $0.u))) }
    }
  }

  func saveSealed(_ engineProfile: String, _ value: LedgerValue, _ replacing: Bool) async throws -> Bool {
    await passGate("saveSealed")
    state.withLock { $0.logins[Self.key(value.o, value.u)] = LocalLogin(value: value, modified: 2_000) }
    return true
  }

  func deletePassword(_ engineProfile: String, _ origin: String, _ username: String) async throws -> Bool {
    await passGate("deletePassword")
    state.withLock { $0.logins[Self.key(origin, username)] = nil }
    return true
  }

  func writeMark(_ engineProfile: String, _ value: String) async throws {
    await passGate("writeMark")
    state.withLock { $0.mark = value }
  }

  func readLedgerDocument() -> DocumentRead { state.withLock { $0.doc.map(DocumentRead.contents) ?? .missing } }

  func writeLedgerDocument(_ contents: String) { state.withLock { $0.doc = contents } }

  func sleep(_ ms: Double) async {}
}

let ledgerSite = "https://site.example"
let ledgerT: Double = 1_000
let ledgerH = "00000000a0000device"

func ledgerUsers(_ n: Int) -> [String] { (0..<n).map { "user\($0)" } }

func ledgerValue(_ u: String, _ s: String = "p") -> LedgerValue { LedgerValue(o: ledgerSite, u: u, s: "\(s)-\(u)") }

func ledgerContext(records: [String: LedgerValue] = [:]) -> ExtractContext {
  ExtractContext(
    base: { _ in nil }, queued: { _ in false }, now: ledgerT, known: { records[$0] != nil }, remote: { records[$0]?.json },
    stamp: { records[$0] == nil ? nil : ledgerH }, downloading: { false })
}

func heldWorld(held: [String]) -> (LedgerTestHost, LedgerPasswordsAdapter, [String: LedgerValue]) {
  let host = LedgerTestHost()
  var records: [String: LedgerValue] = [:]
  var keys = JSONObject()
  for u in ledgerUsers(8) {
    let key = LedgerTestHost.key(ledgerSite, u)
    records[key] = ledgerValue(u)
    keys[key] = ["d": [.string(digestOf(ledgerValue(u)))], "h": .string(ledgerH), "m": .number(500)]
  }
  host.state.withLock { s in
    s.logins[LedgerTestHost.key(ledgerSite, "user7")] = LocalLogin(value: ledgerValue("user7"), modified: 500)
    s.mark = formatMark(Mark(L: 1, t: ledgerT))
    let stored: JSONValue = [
      "v": 1, "L": 1, "t": .number(ledgerT), "keys": .object(keys), "scope": "s", "held": JSONValue(held), "gated": .object(JSONObject()),
    ]
    s.doc = JSONValue.object(["v": 2, "profiles": ["A": stored]]).text()
  }
  var memory = LedgerPasswordsMemory()
  for key in held {
    memory.held.insert(JSKey(key))
    memory.heldDigests[JSKey(key)] = ""
  }
  let adapter = LedgerPasswordsAdapter(host: host, profileId: "A", forced: { true }, ledgerScope: { "s" }, now: { ledgerT }, memory: memory)
  return (host, adapter, records)
}

let sevenGone = ledgerUsers(7).map { LedgerTestHost.key(ledgerSite, $0) }

@Suite struct LedgerPasswordsAdapterTests {
  @Test func secondExtractWhileTheFirstIsParkedReturnsNil() async throws {
    let host = LedgerTestHost()
    let adapter = LedgerPasswordsAdapter(host: host, profileId: "A", forced: { true }, ledgerScope: { "s" }, now: { ledgerT })
    let gate = host.gate("readMarked")
    let first = Task { try await adapter.extract(ledgerContext()) != nil }
    await gate.waitReached()
    let second = try await adapter.extract(ledgerContext())
    #expect(second == nil)
    #expect(host.count("readMarked") == 1)
    gate.open()
    #expect(try await first.value)
  }

  @Test func aThrowFromCheckSealedDoesNotLeaveExtractLocked() async throws {
    let host = LedgerTestHost()
    host.state.withLock { $0.logins[LedgerTestHost.key(ledgerSite, "user0")] = LocalLogin(value: ledgerValue("user0"), modified: 500) }
    let adapter = LedgerPasswordsAdapter(host: host, profileId: "A", forced: { true }, ledgerScope: { "s" }, now: { ledgerT })
    host.state.withLock { $0.failCheck = true }
    await #expect(throws: SyncError.self) { try await adapter.extract(ledgerContext()) }
    host.state.withLock { $0.failCheck = false }
    #expect(try await adapter.extract(ledgerContext()) != nil)
    #expect(host.count("readMarked") == 2)
  }

  @Test(arguments: [HeldChoice.confirm, .restore])
  func aChoiceMadeWhileALedgerWriteWaitsOnTheMarkIsNotUndone(_ choice: HeldChoice) async throws {
    let (host, adapter, _) = heldWorld(held: sevenGone)
    #expect(adapter.held() == 7)
    let changed = LedgerTestHost.key(ledgerSite, "user7")
    let gate = host.gate("writeMark")
    let applying = Task { try await adapter.applyKeys([(changed, ledgerValue("user7", "changed").json)], [changed], { _ in nil }, ApplyRecords(known: { _ in true }, now: ledgerT, horizon: 0, joined: true)) }
    await gate.waitReached()
    adapter.resolveHeld(choice)
    #expect(host.ledger?["profiles"]?["A"]?["held"] == JSONValue([String]()))
    gate.open()
    #expect(try await applying.value == .written([changed]))
    #expect((host.ledger?["profiles"]?["A"]?["L"]?.number ?? 0) > 1)
    #expect(host.ledger?["profiles"]?["A"]?["held"] == JSONValue([String]()))
    #expect(adapter.held() == 0)
    if choice == .confirm {
      #expect(adapter.memory.confirmed == OrderedSet(sevenGone.map(JSKey.init)))
    } else {
      #expect(adapter.memory.restoring.keys == sevenGone.map(JSKey.init))
    }
  }

  @Test(arguments: [HeldChoice?.none, .confirm, .restore])
  func aChoiceMadeWhileExtractWaitsOnTheRecordCheckSurvives(_ choice: HeldChoice?) async throws {
    let (host, adapter, records) = heldWorld(held: sevenGone)
    let gate = host.gate("checkSealed#2")
    let extracting = Task {
      let extraction = try await adapter.extract(ledgerContext(records: records))
      return (extraction?.remove ?? [], extraction?.reapply ?? [])
    }
    await gate.waitReached()
    if let choice { adapter.resolveHeld(choice) }
    gate.open()
    let (remove, reapply) = try await extracting.value
    switch choice {
    case nil:
      #expect(adapter.held() == 7)
      #expect(remove.isEmpty)
    case .confirm:
      #expect(adapter.held() == 0)
      #expect(remove == sevenGone)
    case .restore:
      #expect(adapter.held() == 0)
      #expect(remove.isEmpty)
      #expect(OrderedSet(reapply) == OrderedSet(sevenGone))
    }
  }
}
