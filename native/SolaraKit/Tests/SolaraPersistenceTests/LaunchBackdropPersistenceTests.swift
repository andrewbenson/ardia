import Foundation
import SolaraModel
import SolaraPersistence
import SolaraStore
import Testing

@Suite struct LaunchBackdropPersistenceTests {
  @Test func rowsAndShadowUseTheCurrentProfileThemeAtExport() throws {
    let folder = try scratchFolder()
    defer { try? FileManager.default.removeItem(at: folder.url) }
    let launch = try open(folder)
    let store = store(for: launch)
    let writer = PersistenceWriter(store: store, database: launch.database, folder: folder, persisted: launch.persisted)
    defer { writer.freeze() }
    let id = try #require(try store.dispatch(Command("createWindow", [["url": "https://example.com/"]])).result?.string)
    try store.dispatch(Command("setFocusedWindow", [.string(id)]))
    #expect(writer.flush(timeout: 5) == .saved)
    let first = try JSONValue.parse(Data(contentsOf: folder.session))["launchBackdrop"]
    #expect(first != nil && first != .null)
    #expect(try launch.database.load().workspace?.values["launchBackdrop"].flatMap { try? JSONValue.parse($0) } == first)
    try store.dispatch(Command("updateProfile", ["default", ["color": "blue"]]))
    try store.updateAppAppearance(true)
    #expect(writer.flush(timeout: 5) == .saved)
    let second = try JSONValue.parse(Data(contentsOf: folder.session))["launchBackdrop"]
    #expect(second?["dark"] == .bool(true))
    #expect(second != first)
    #expect(try launch.database.load().workspace?.values["launchBackdrop"].flatMap { try? JSONValue.parse($0) } == second)
    try store.updateAppAppearance(false)
    #expect(writer.flush(timeout: 5) == .saved)
    let third = try JSONValue.parse(Data(contentsOf: folder.session))["launchBackdrop"]
    #expect(third?["dark"] == .bool(false))
    #expect(third != second)
    #expect(try launch.database.load().workspace?.values["launchBackdrop"].flatMap { try? JSONValue.parse($0) } == third)
  }
}
