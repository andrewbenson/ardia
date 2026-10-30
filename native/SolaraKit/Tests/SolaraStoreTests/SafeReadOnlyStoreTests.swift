import SolaraModel
import SolaraStore
import Synchronization
import Testing

@Suite struct SafeReadOnlyStoreTests {
  let reason = "Safe mode could not open the database. Changes to settings and downloads cannot be saved. Open Solara normally to make these changes."

  final class Refusals: Sendable {
    let messages = Mutex<[String]>([])
  }

  func store(refusals: Refusals) -> Store {
    var config = StoreConfig()
    config.safeMode = true
    config.persistenceRefusal = reason
    return Store(
      state: BrowserState(settings: Settings.hydrated(from: nil)), memory: StoreMemory(ids: IdSource(launch: "safe-read-only")), config: config,
      checksInvariants: true, onPersistenceRefusal: { message in refusals.messages.withLock { $0.append(message) } }, clock: { 1_000 })
  }

  @Test func unavailablePersistenceRefusesCommandAndDirectEditsBeforeSuccess() throws {
    let refusals = Refusals()
    let store = store(refusals: refusals)
    let before = store.state
    let ids = store.memory.ids
    let seen = Seen()
    store.subscribe { seen.append($0.rev) }
    let edits: [Command] = [
      Command("updateSettings", [["appearance": "dark"]]),
      Command("upsertDownload", [["id": "refused", "url": "https://refused.example/file.zip", "state": "complete", "profile": ""]])
    ]
    for command in edits {
      do {
        try store.dispatch(command)
        Issue.record("An edit reported success without persistence")
      } catch {
        #expect(String(describing: error) == reason)
      }
      #expect(store.state == before)
      #expect(store.memory.ids == ids)
      #expect(store.rev == 0)
    }
    do {
      try store.transact { session in
        _ = session.newId("refused")
        session.emit(.cancelDownload(id: "refused"))
        session.updateSettings(["appearance": "dark"], fromSync: false)
      }
      Issue.record("A direct edit reported success without persistence")
    } catch {
      #expect(String(describing: error) == reason)
    }
    #expect(store.state == before)
    #expect(store.memory.ids == ids)
    #expect(store.rev == 0)
    #expect(seen.values.isEmpty)
    #expect(refusals.messages.withLock { $0 } == [reason, reason, reason])
  }

  @Test func refusalRestoresHeldTransactionAndAllowsLaterTransientWork() throws {
    let refusals = Refusals()
    let store = store(refusals: refusals)
    try store.dispatch(Command("beginTransaction"))
    let before = store.state
    let ids = store.memory.ids
    do {
      try store.transact { session in
        session.beginTransaction()
        session.emit(.cancelDownload(id: "refused"))
        _ = session.createWindow()
        session.updateSettings(["appearance": "dark"], fromSync: false)
      }
      Issue.record("A held edit reported success without persistence")
    } catch {
      #expect(String(describing: error) == reason)
    }
    #expect(store.state == before)
    #expect(store.memory.ids == ids)
    #expect(store.rev == 0)
    try store.dispatch(Command("createWindow", [["url": "https://temporary.example/"]]))
    let window = try #require(store.state.windowOrder.first)
    let tab = try #require(store.state.windows[window]?.tabIds.first)
    try store.dispatch(Command("navigate", [.string(tab), "https://temporary.example/next"]))
    let commit = try store.dispatch(Command("endTransaction"))
    #expect(store.state.windows.count == 1)
    #expect(store.state.tabs[tab]?.navigation?.url == "https://temporary.example/next")
    #expect(!commit.effects.contains(.cancelDownload(id: "refused")))
    let unchanged = try store.dispatch(Command("updateSettings", [.object([:])]))
    #expect(unchanged.state.settings == before.settings)
  }

  @Test func privateDownloadsAndTransientWindowsDoNotRequirePersistence() throws {
    let refusals = Refusals()
    let store = store(refusals: refusals)
    let window = try #require(try store.dispatch(Command("createWindow", [["incognito": true]])).result?.string)
    let profile = try #require(store.state.windows[window]?.profileId)
    let session = try #require(store.state.privateSession(profile))
    try store.dispatch(Command("upsertDownload", [["id": "private", "url": "https://private.example/file.zip", "state": "complete", "offTheRecord": true, "profile": .string(session)]]))
    #expect(store.state.downloads.contains { $0.id == "private" })
    #expect(refusals.messages.withLock { $0.isEmpty })
  }
}
