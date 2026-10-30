import Foundation
import SolaraBridgeCore
import SolaraModel
import SolaraStore
import Synchronization
import Testing

@Suite struct TransactionTests {
  @Test(arguments: [false, true]) func reentrantListenerCanQueueBehindANewerUserTransactionWithoutDeadlock(_ redesign: Bool) throws {
    let bridge = SyncPinsBridgeTests().seeded(redesign)
    let store = bridge.store
    let ran = Mutex(false)
    let seen = Mutex<[Int]>([])
    store.subscribe { commit in
      seen.withLock { $0.append(commit.rev) }
      guard ran.withLock({ value in
        if value { return false }
        value = true
        return true
      }) else { return }
      try! store.dispatch(Command("beginTransaction"))
      try! store.dispatch(Command("settlePinChoices", ["default", ["place:t": 10, "place:u": 11]]))
    }
    try store.dispatch(Command("updateTab", ["t", ["customTitle": "User"]]))
    #expect(store.queuedFromSyncCount == 1)
    try store.dispatch(Command("applyState", [["pinChoices": ["default": ["place:t": 20, "place:u": 11]]]]))
    try store.dispatch(Command("endTransaction"))
    #expect(store.queuedFromSyncCount == 0)
    #expect(store.state.pinChoices["default"]?["place:t"] == 20)
    #expect(store.state.pinChoices["default"]?["place:u"] == nil)
    #expect(seen.withLock { $0 == $0.sorted() })
  }

  @Test(arguments: [false, true]) func bothDeferredEntryPointsWaitUntilTheOuterTransactionEnds(_ redesign: Bool) throws {
    let bridge = SyncPinsBridgeTests().seeded(redesign)
    let store = bridge.store
    let order = Mutex<[Int]>([])
    try store.dispatch(Command("beginTransaction"))
    try store.dispatch(Command("beginTransaction"))
    try store.transactWhenFree { session in
      order.withLock { $0.append(1) }
      session.settlePinChoices("default", JSMap([("place:t", 10)]))
    }
    try store.dispatch(Command("settlePinChoices", ["default", ["place:u": 11]]))
    try store.transactWhenFree { _ in order.withLock { $0.append(2) } }
    #expect(store.queuedFromSyncCount == 3)
    try store.dispatch(Command("endTransaction"))
    #expect(store.queuedFromSyncCount == 3)
    try store.dispatch(Command("endTransaction"))
    #expect(order.withLock { $0 } == [1, 2])
    #expect(store.queuedFromSyncCount == 0)
    #expect(store.state.pinChoices["default"] == nil)
  }

  @Test(arguments: [false, true]) func hydrateRunsImmediatelyWhileSettlementWaitsAndUsesTheHydratedStamp(_ redesign: Bool) throws {
    let store = SyncPinsBridgeTests().seeded(redesign).store
    try store.dispatch(Command("beginTransaction"))
    try store.dispatch(Command("settlePinChoices", ["default", ["place:t": 10]]))
    var data = store.state.stateJSON
    data["pinChoices"] = ["default": ["place:t": 30]]
    try store.dispatch(Command("hydrate", [.object(data)]))
    #expect(store.state.pinChoices["default"]?["place:t"] == 30)
    #expect(store.queuedFromSyncCount == 1)
    try store.dispatch(Command("closeTransactions"))
    #expect(store.state.pinChoices["default"]?["place:t"] == 30)
    #expect(store.queuedFromSyncCount == 0)
  }

  @Test func anAbandonedTransactionOnlyExpiresOnTheNextStoreOperation() throws {
    let now = Mutex<Double>(1_000)
    let store = SyncPinsBridgeTests().seeded(false, clock: { now.withLock { $0 } }).store
    try store.dispatch(Command("beginTransaction"))
    try store.transactWhenFree { $0.settlePinChoices("default", JSMap([("place:t", 10)])) }
    now.withLock { $0 += Store.heldTransactionLimit + 1 }
    #expect(store.queuedFromSyncCount == 1)
    #expect(store.state.pinChoices["default"]?["place:t"] == 10)
    try store.dispatch(Command("nextId", ["probe"]))
    #expect(store.queuedFromSyncCount == 0)
    #expect(store.state.pinChoices["default"]?["place:t"] == nil)
  }
}
