import SolaraModel
import SolaraStore
import Testing

@MainActor
@Suite struct SettingsModelTests {
  @Test func updatesDispatchTheCommandAndCommitsFromElsewhereArrive() async throws {
    let store = Store(checksInvariants: true)
    let model = SettingsModel(store: store)
    model.update(["appearance": "dark"])
    #expect(model.value("appearance") == "dark")
    #expect(store.state.settings["appearance"] == "dark")
    #expect(store.state.settings.strings("chosen")?.contains("appearance") == true)
    try store.dispatch(Command("updateSettings", [["searchEngine": "bing"]]), origin: .bridge)
    try store.dispatch(Command("applyState", [["profiles": ["default": ["id": "default", "name": "Personal", "color": "plum", "icon": .null, "createdAt": 0], "work": ["id": "work", "name": "Work", "color": "blue", "icon": .null, "createdAt": 1]], "profileOrder": ["default", "work"]]]), origin: .bridge)
    for _ in 0..<50 where model.value("searchEngine") != "bing" || model.profiles.count != 2 { await Task.yield() }
    #expect(model.value("searchEngine") == "bing")
    #expect(model.profiles.map(\.name) == ["Personal", "Work"])
  }
}
