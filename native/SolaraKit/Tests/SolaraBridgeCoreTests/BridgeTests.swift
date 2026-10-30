import Foundation
import SolaraBridgeCore
import SolaraModel
import SolaraStore
import Testing

@Suite struct BridgeTests {
  func bridge() -> StoreBridge {
    StoreBridge(store: Store(state: BrowserState(settings: Settings.hydrated(from: nil)), memory: StoreMemory(ids: IdSource(launch: "t")), checksInvariants: true, clock: { 1 }))
  }

  @Test func dispatchReturnsEveryPatchSinceTheCallersRevIncludingItsOwn() throws {
    let bridge = bridge()
    _ = bridge.dispatch(#"{"name":"updateSettings","args":[{"tabLayout":"top"},{"fromSync":true}]}"#, sinceRev: 0)
    let response = try JSONValue.parse(bridge.dispatch(#"{"name":"updateSettings","args":[{"appearance":"light"}]}"#, sinceRev: 0))
    #expect(response["rev"] == 2)
    #expect(response["patches"]?.array?.count == 2)
    #expect(response["patches"]?.array?.last?["settings"]?["set"]?["appearance"] == "light")
  }

  @Test func aBatchIsOneCommitAndEffectsComeBack() throws {
    let bridge = bridge()
    let response = try JSONValue.parse(bridge.dispatch(#"[{"name":"createWindow","args":[{}]},{"name":"upsertDownload","args":[{"id":"a","state":"complete","profile":""}]},{"name":"upsertDownload","args":[{"id":"b","state":"complete"}]}]"#, sinceRev: 0))
    #expect(response["rev"] == 1)
    #expect(response["effects"]?.array?.contains { $0["type"] == "openDownloads" } != true)
    #expect(response["patches"]?.array?.first?["windowUi"]?["upsert"]?.array?.first?["state"]?["downloadsOpen"] == true)
    #expect(response["patches"]?.array?.first?["downloads"]?.array?.count == 2)
    #expect(response["patches"]?.array?.first?["windows"]?["upsert"]?.array?.count == 1)
  }

  @Test func errorsComeBackWithTheCatchUp() throws {
    let bridge = bridge()
    let response = try JSONValue.parse(bridge.dispatch(#"{"name":"nope"}"#, sinceRev: 0))
    #expect(response["error"]?.string?.contains("unknown command") == true)
    #expect(response["rev"] == 0)
    #expect(response["patches"] == [])
  }

  @Test func aCallerTooFarBehindGetsASnapshot() throws {
    let bridge = bridge()
    for i in 0..<(Store.ringSize + 2) {
      _ = bridge.dispatch(#"{"name":"updateSettings","args":[{"sidebarWidth":\#(i)},{"fromSync":true}]}"#, sinceRev: i)
    }
    let response = bridge.catchUp(sinceRev: 0)
    #expect(response["snapshot"]?["settings"]?["sidebarWidth"] == .number(Double(Store.ringSize + 1)))
    #expect(response["patches"] == nil)
  }

  @Test func foreignCommitsAreReportedAndBridgeOnesAreNot() throws {
    let bridge = bridge()
    let events = Events()
    bridge.observeForeignCommits { events.append($0) }
    _ = bridge.dispatch(#"{"name":"updateSettings","args":[{"appearance":"dark"}]}"#, sinceRev: 0)
    try bridge.store.dispatch(Command("updateSettings", [["appearance": "light"], ["fromSync": true]]), origin: .sync)
    #expect(events.values.count == 1)
    #expect(try JSONValue.parse(events.values[0])["rev"] == 2)
  }
}

final class Events: @unchecked Sendable {
  private let lock = NSLock()
  private var items: [String] = []
  func append(_ item: String) { lock.withLock { items.append(item) } }
  var values: [String] { lock.withLock { items } }
}
