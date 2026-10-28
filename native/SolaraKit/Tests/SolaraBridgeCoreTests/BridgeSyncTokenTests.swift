import Foundation
import SolaraBridgeCore
import SolaraModel
import SolaraStore
import Testing

@Suite struct BridgeSyncTokenTests {
  func settings(_ patch: JSONObject, fromSync: Bool = false) -> JSONValue {
    Command("updateSettings", [.object(patch), ["fromSync": .bool(fromSync)]]).json
  }

  @Test func theBridgeReadsTheSyncTokenFromItsEnvelope() throws {
    var config = StoreConfig()
    config.syncOrigins = true
    let store = Store(state: BrowserState(settings: Settings.hydrated(from: nil)), memory: StoreMemory(ids: IdSource(launch: "token")), config: config, checksInvariants: true, clock: { 1_000 })
    let bridge = StoreBridge(store: store)
    let envelope: JSONValue = ["fromSync": true, "commands": [settings(["appearance": "dark"], fromSync: true)]]
    let tagged = bridge.dispatch(json: envelope.text(), sinceRev: 0)
    #expect(tagged["error"] == nil)
    #expect(tagged["patches"]?.array?.last?["sync"] == true)
    #expect(store.state.settings["appearance"] == "dark")
    let plain = bridge.dispatch(json: JSONValue.array([settings(["searchEngine": "bing"])]).text(), sinceRev: store.rev)
    #expect(plain["patches"]?.array?.last?["sync"] == nil)
    let single = bridge.dispatch(json: settings(["searchEngine": "duckduckgo"]).text(), sinceRev: store.rev)
    #expect(single["error"] == nil, "a bare command still parses")
  }

  @Test func aSyncCallDuringAUserTransactionComesBackBusySoJSRetriesFromFreshState() throws {
    var config = StoreConfig()
    config.syncOrigins = true
    let store = Store(state: BrowserState(settings: Settings.hydrated(from: nil)), memory: StoreMemory(ids: IdSource(launch: "token")), config: config, checksInvariants: true, clock: { 1_000 })
    let bridge = StoreBridge(store: store)
    _ = bridge.dispatch(json: Command("beginTransaction").json.text(), sinceRev: 0)
    let envelope: JSONValue = ["fromSync": true, "commands": [settings(["appearance": "dark"], fromSync: true)]]
    let busy = bridge.dispatch(json: envelope.text(), sinceRev: store.rev)
    #expect(busy["busy"] == true)
    #expect(busy["error"] == nil)
    #expect(store.state.settings["appearance"] != "dark")
    _ = bridge.dispatch(json: Command("endTransaction").json.text(), sinceRev: store.rev)
    let retried = bridge.dispatch(json: envelope.text(), sinceRev: store.rev)
    #expect(retried["busy"] == nil)
    #expect(store.state.settings["appearance"] == "dark")
  }
}
