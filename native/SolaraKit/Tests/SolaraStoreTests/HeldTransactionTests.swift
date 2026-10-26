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
}

extension JSMap where Value == JSONValue {
  var canonicalText: String { JSONValue.object(self).canonical }
}
