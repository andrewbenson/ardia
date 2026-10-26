import SolaraModel
import SolaraStore
import Testing

@Suite struct HeldTransactionTests {
  func seeded() throws -> Store {
    let store = Store(memory: StoreMemory(ids: IdSource(launch: "held")), checksInvariants: true, clock: { 1_793_016_000_000 })
    try store.dispatch(Command("createWindow", [["url": "https://a.example/"]]))
    return store
  }

  func commands(_ store: Store) -> [Command] {
    let window = store.state.windowOrder[0]
    return [
      Command("newTab", [.string(window), ["url": "https://b.example/"]]),
      Command("newTab", [.string(window), ["url": "https://c.example/"]]),
      Command("createGroup", [JSONValue(store.state.windows[window]!.tabIds), ["name": "G"]]),
    ]
  }

  @Test func dispatchesBetweenBeginAndEndSettleLikeOneBatch() throws {
    let batched = try seeded()
    try batched.dispatch(commands(batched))
    let held = try seeded()
    let list = commands(held)
    try held.dispatch(Command("beginTransaction"))
    var revs: [Int] = []
    for command in list { revs.append(try held.dispatch(command).rev) }
    try held.dispatch(Command("endTransaction"))
    #expect(revs == revs.sorted())
    #expect(held.state.stateJSON.canonicalText == batched.state.stateJSON.canonicalText)
  }

  @Test func aTransactionLeftOpenIsClosedByCommandOrByTime() throws {
    final class Clock: @unchecked Sendable { var now: Double = 1_000 }
    let clock = Clock()
    let store = Store(memory: StoreMemory(ids: IdSource(launch: "held")), checksInvariants: true, clock: { clock.now })
    try store.dispatch(Command("createWindow", [["url": "https://a.example/"]]))
    try store.dispatch(Command("beginTransaction"))
    try store.dispatch(Command("closeTransactions"))
    let window = store.state.windowOrder[0]
    try store.dispatch(Command("beginTransaction"))
    clock.now += Store.heldTransactionLimit + 1
    try store.dispatch(Command("newTab", [.string(window), ["url": "https://b.example/"]]))
    let batched = try seeded()
    try batched.dispatch(Command("newTab", [.string(batched.state.windowOrder[0]), ["url": "https://b.example/"]]))
    #expect(store.state.windows[window]!.tabIds.count == batched.state.windows[batched.state.windowOrder[0]]!.tabIds.count)
    try store.dispatch(Command("endTransaction"))
  }
}

extension JSMap where Value == JSONValue {
  var canonicalText: String { JSONValue.object(self).canonical }
}
