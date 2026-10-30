import Foundation
import SolaraModel
import SolaraOmnibox
import SolaraStore
import Testing
@testable import SolaraUI

private func workspaceRows(_ rows: [TabRow]) -> JSONValue {
  .array(rows.map { ["id": .string($0.id), "url": .string($0.url), "title": .string($0.title), "favicon": JSONValue($0.favicon)] })
}

@Suite struct OmniboxWorkspaceSourcesTests {
  @Test func projectionsMatchActualJavaScriptPublishers() throws {
    let path = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("SolaraOmniboxTests/Fixtures/workspace-sources.json")
    let fixture = try JSONValue.parse(Data(contentsOf: path))
    for item in fixture["cases"]!.array! {
      var state = BrowserState()
      state.profiles = Table()
      for value in item["profiles"]!.array! {
        let profile = try Profile(json: value.object!)
        state.profiles[profile.id] = profile
      }
      for value in item["windows"]!.array! {
        let window = try BrowserWindow(json: value.object!)
        state.windows[window.id] = window
      }
      for value in item["tabs"]!.array! {
        let tab = try Tab(json: value.object!)
        state.tabs[tab.id] = tab
      }
      let projection = OmniboxWorkspaceSources(state)
      let expected = item["expected"]!.array!
      #expect(projection.profiles.map(\.profileId) == expected.map { $0["profileId"]!.string! }, "\(item["name"]!)")
      for (actual, expected) in zip(projection.profiles, expected) {
        #expect(actual.engineProfile == expected["engineProfile"]!.string!)
        #expect(actual.bookmarkEngineProfile == expected["bookmarkEngineProfile"]!.string!)
        #expect(workspaceRows(actual.tabs) == expected["tabs"]!, "\(item["name"]!) \(actual.profileId)")
      }
    }
  }

  @Test func tablePreservesNumericOrderingAndNamedReinsertion() {
    var table = Table<Tab>()
    for id in ["last", "10", "2", "01", "0", "4294967295", "4294967294"] {
      table[id] = Tab(id: id, windowId: "w", profileId: "default", url: "", now: 0)
    }
    table["last"] = Tab(id: "last", windowId: "w", profileId: "default", url: "updated", now: 0)
    #expect(table.values.map(\.id) == ["0", "2", "10", "4294967294", "last", "01", "4294967295"])
    table["last"] = nil
    table["last"] = Tab(id: "last", windowId: "w", profileId: "default", url: "", now: 0)
    #expect(table.values.map(\.id) == ["0", "2", "10", "4294967294", "01", "4294967295", "last"])
  }
}
