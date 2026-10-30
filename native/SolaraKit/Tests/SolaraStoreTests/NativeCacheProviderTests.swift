import Foundation
import SolaraModel
import SolaraStore
import Testing

@Suite struct NativeCacheProviderTests {
  @Test func launchSwitchUsesEnvironmentThenCacheThenOn() throws {
    for cached in [nil, true, false] as [Bool?] {
      let cache = cached.map { Data("{\"switches\":{\"launchTab\":\($0)}}".utf8) }
      for override in [nil, "on", "off"] as [String?] {
        let environment = override.map { "other=off, launchTab=\($0)" }
        let expected = override.map { $0 == "on" } ?? cached ?? true
        #expect(EarlyLaunchTabProvider.resolve(environment: environment, cache: cache) == expected)
      }
    }
    for value in ["off", "0", "false"] {
      #expect(!EarlyLaunchTabProvider.resolve(environment: "launchTab=\(value)", cache: nil))
    }
    for value in ["on", "1", "true"] {
      #expect(EarlyLaunchTabProvider.resolve(environment: "launchTab=\(value)", cache: nil))
    }
    #expect(!EarlyLaunchTabProvider.resolve(environment: "launchTab=on,launchTab=off,launchTab=invalid", cache: nil))
    #expect(EarlyLaunchTabProvider.resolve(environment: "launchTab=OFF", cache: Data("bad".utf8)))
    #expect(EarlyLaunchTabProvider.resolve(environment: nil, cache: Data("{\"switches\":{\"launchTab\":0}}".utf8)))
  }

  @Test func launchSwitchRefreshUpdatesTheExportWithoutJS() throws {
    let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let url = folder.appending(path: "switches-cache.json")
    let store = makeStore()
    try store.dispatch(Command("createWindow", [["url": "https://launch.test/"]]))
    let provider = EarlyLaunchTabProvider(store: store, environment: nil, readCache: { try? Data(contentsOf: url) })
    try provider.refresh()
    #expect(store.sessionDocument().launchTab != .null)
    try Data("{\"switches\":{\"launchTab\":false}}".utf8).write(to: url, options: .atomic)
    try provider.refresh()
    #expect(store.sessionDocument().launchTab == .null)
    #expect(store.sessionDocument().linkProfile == .null)
    try Data("{\"switches\":{\"launchTab\":true}}".utf8).write(to: url, options: .atomic)
    try provider.refresh()
    #expect(store.sessionDocument().launchTab != .null)
    let overridden = EarlyLaunchTabProvider(store: store, environment: "launchTab=off", readCache: { try? Data(contentsOf: url) })
    try overridden.refresh()
    #expect(store.sessionDocument().launchTab == .null)
  }

  @Test func lastTabPolicyComesFromNativeEngineReply() throws {
    let store = makeStore()
    let provider = LastTabPolicyProvider(store: store)
    try provider.receive(["closesWindow": false])
    #expect(store.memory.lastTabKeepsWindow)
    try provider.receive(["error": "unavailable"])
    #expect(!store.memory.lastTabKeepsWindow)
    try provider.receive(["closesWindow": true])
    #expect(!store.memory.lastTabKeepsWindow)
    try provider.receive(.null)
    #expect(!store.memory.lastTabKeepsWindow)
  }

  @Test func nativeAppearanceRefreshInvalidatesExportInputs() throws {
    let store = makeStore()
    try store.updateAppAppearance(true)
    #expect(store.state.caches.systemDark)
    let rev = store.rev
    try store.updateAppAppearance(true)
    #expect(store.rev == rev)
    try store.updateAppAppearance(false)
    #expect(!store.state.caches.systemDark)
  }
}
