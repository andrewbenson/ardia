import Foundation
import SolaraModel
import SolaraStore
import Testing

final class TestClock: @unchecked Sendable {
  private let lock = NSLock()
  private var value: Double
  init(_ value: Double) { self.value = value }
  var now: Double { lock.withLock { value } }
  func advance(_ ms: Double) { lock.withLock { value += ms } }
}

private let hour: Double = 3_600_000
private let start: Double = 1_800_000_000_000

private struct CleanUpFixture {
  let clock = TestClock(start)
  let store: Store
  var windowId = ""

  init() {
    let clock = clock
    store = Store(state: BrowserState(settings: Settings.hydrated(from: nil)), memory: StoreMemory(ids: IdSource(launch: "test")), checksInvariants: true, clock: { clock.now })
  }

  mutating func setup(_ hosts: [String]) throws -> [String] {
    windowId = try run("createWindow", ["url": .string("\(hosts[0]).com")]).string ?? ""
    var ids = [store.state.windows[windowId]!.tabIds[0]]
    for host in hosts.dropFirst() { ids.append(try run("newTab", .string(windowId), ["url": .string("\(host).com")]).string ?? "") }
    _ = try run("activate", .string(ids[0]))
    return ids
  }

  @discardableResult
  func run(_ name: String, _ args: JSONValue...) throws -> JSONValue {
    try store.dispatch(Command(name, args)).result ?? .null
  }

  func idle(_ id: String, _ ms: Double) throws {
    try run("updateTab", .string(id), ["lastActiveAt": .number(clock.now - ms)])
  }

  func cleanUp(inactiveForMs: Double? = nil) throws -> [String] {
    let before = Set(store.state.tabs.keys)
    let options: JSONValue = inactiveForMs.map { ["inactiveForMs": .number($0)] } ?? [:]
    let count = try run("cleanUpTabs", .string(windowId), options).number ?? 0
    let closed = before.subtracting(store.state.tabs.keys).sorted()
    #expect(Double(closed.count) == count)
    return closed
  }

  mutating func duplicated() throws -> (ids: [String], copies: [String]) {
    let ids = try setup((0..<8).map { "p\($0)" })
    let copies = try ids.map { try run("duplicateTab", .string($0)).string ?? "" }
    try run("activate", .string(ids[0]))
    return (ids, copies)
  }
}

@Suite struct CleanUpTests {
  @Test func tabsDuplicatedAMomentAgoAreLeftAlone() throws {
    var f = CleanUpFixture()
    _ = try f.duplicated()
    #expect(f.store.state.windows[f.windowId]!.tabIds.count == 16)
    #expect(try f.cleanUp() == [])
  }

  @Test func aDuplicateIdleForAnHourIsOffered() throws {
    var f = CleanUpFixture()
    let (ids, _) = try f.duplicated()
    let urls = ids.map { f.store.state.tabs[$0]!.url }.sorted()
    f.clock.advance(2 * hour)
    let before = f.store.state
    let closed = try f.cleanUp()
    #expect(closed.count == 8)
    #expect(!closed.contains(ids[0]))
    #expect(closed.map { before.tabs[$0]!.url }.sorted() == urls)
  }

  @Test func aGroupedDuplicateIdlePastTheHourIsStillOffered() throws {
    var f = CleanUpFixture()
    let ids = try f.setup(["a", "b"])
    let copy = try f.run("duplicateTab", .string(ids[1])).string ?? ""
    try f.run("createGroup", [.string(copy)], ["name": "G"])
    try f.run("activate", .string(ids[0]))
    try f.idle(copy, 30 * 60_000)
    #expect(try f.cleanUp() == [])
    try f.idle(copy, 2 * hour)
    #expect(try f.cleanUp() == [copy])
  }

  @Test func aShorterSettingShortensTheWaitForAGroupedDuplicate() throws {
    var f = CleanUpFixture()
    let ids = try f.setup(["a", "b"])
    let copy = try f.run("duplicateTab", .string(ids[1])).string ?? ""
    try f.run("createGroup", [.string(copy)], ["name": "G"])
    try f.run("activate", .string(ids[0]))
    try f.idle(copy, 30 * 60_000)
    #expect(try f.cleanUp(inactiveForMs: 20 * 60_000) == [copy])
  }

  @Test func aTabThatIsNoDuplicateIsOfferedOnlyAfterTwelveHours() throws {
    var f = CleanUpFixture()
    let ids = try f.setup(["a", "b"])
    try f.idle(ids[1], 11 * hour)
    #expect(try f.cleanUp() == [])
    try f.idle(ids[1], 13 * hour)
    #expect(try f.cleanUp() == [ids[1]])
  }
}
