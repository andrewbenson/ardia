import SolaraEngine
import Testing
@testable import SolaraUI

@MainActor
struct HistoryCatalogPageTests {
  @Test func snapshotReadinessAndSelectionFollowTheCatalog() {
    let model = HistoryPageModel()
    let first = HistoryEntry(url: "https://a.example/", title: "A", visits: 2, lastVisit: 20, visitTimes: [10, 20])
    let second = HistoryEntry(url: "https://b.example/", title: "B", visits: 1, lastVisit: 10, visitTimes: [10])
    model.apply(snapshot: HistorySnapshot(entries: [first], ready: false))
    #expect(model.entries.isEmpty)
    model.apply(snapshot: HistorySnapshot(entries: [first, second], ready: true))
    #expect(model.shown == ["https://a.example/", "https://b.example/"])
    #expect(model.entries.first?.title == "A")
    #expect(model.entries.first?.favicon == nil)
    model.selected = [first.url, second.url]
    model.apply(snapshot: HistorySnapshot(entries: [second], ready: true))
    #expect(model.shown == [second.url])
    #expect(model.selected == [second.url])
  }
}
