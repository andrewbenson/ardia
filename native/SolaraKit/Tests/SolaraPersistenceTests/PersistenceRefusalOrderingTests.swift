import Foundation
import Synchronization
import SolaraModel
import SolaraStore
import Testing

@Suite struct PersistenceRefusalOrderingTests {
  @Test func refusalHookFiresBeforeTheRefusedDispatchThrowsInsideAListener() throws {
    var config = StoreConfig()
    config.safeMode = true
    config.persistenceRefusal = "refused"
    let order = Mutex<[String]>([])
    let store = Store(
      state: BrowserState(settings: Settings.hydrated(from: nil)), memory: StoreMemory(ids: IdSource(launch: "repro")), config: config,
      checksInvariants: true, onPersistenceRefusal: { _ in order.withLock { $0.append("hook") } }, clock: { 1_000 })
    let once = Mutex(false)
    let id = store.subscribe { _ in
      guard once.withLock({ let was = $0; $0 = true; return !was }) else { return }
      do { try store.dispatch(Command("updateSettings", [["appearance": "dark"]])) } catch { order.withLock { $0.append("thrown") } }
    }
    defer { store.unsubscribe(id) }
    _ = try store.dispatch(Command("createWindow", [["url": "https://repro.example/"]]))
    #expect(order.withLock { $0 } == ["hook", "thrown"])
  }
}
