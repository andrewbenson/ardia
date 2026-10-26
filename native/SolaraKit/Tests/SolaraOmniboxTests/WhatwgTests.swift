import Foundation
import SolaraModel
import Testing

@testable import SolaraOmnibox

@Suite struct WhatwgDifferential {
  @Test func gettersMatchNewURL() throws {
    var m = Mismatches()
    var parsed = 0
    for c in try Fixture.load("whatwg.json").items {
      let input = c[0]!.str
      let want = c[1]!
      guard let u = WhatwgURL(input) else {
        m.check("parse \(describe(c[0]))", .null, want.isNull ? .null : .string("parses"))
        continue
      }
      if want.isNull {
        m.check("parse \(describe(c[0]))", .string(u.href), .null)
        continue
      }
      parsed += 1
      let got = obj([
        "protocol": .string(u.protocol), "username": .string(u.usernameText), "password": .string(u.passwordText), "hostname": .string(u.hostname),
        "host": .string(u.host), "port": .string(u.port), "pathname": .string(u.pathname), "search": .string(u.search), "hash": .string(u.hash), "href": .string(u.href),
      ])
      m.check("new URL \(describe(c[0]))", got, want)
    }
    #expect(parsed > 1000)
    #expect(m.total == 0, "\(m.report)")
  }

  @Test func theStoresUses() {
    #expect(WhatwgURL("https://Example.com:443/a")?.host == "example.com")
    #expect(WhatwgURL("https://example.com:8443/a")?.host == "example.com:8443")
    #expect(WhatwgURL("file:///Users/me/My%20File.html")?.pathname == "/Users/me/My%20File.html")
    #expect(WhatwgURL("ardia://flags")?.hostname == "flags")
    #expect(WhatwgURL("about:blank")?.hostname == "")
    #expect(WhatwgURL("not a url") == nil)
    #expect(WhatwgURL("https://exa mple.com/") == nil)
  }
}

private func settings(_ values: JSONObject) -> Settings {
  var all = Settings.defaults.values
  for (key, value) in values { all[key] = value }
  return Settings(values: all)
}

@Suite struct SettingsEngineTests {
  @Test func defaultsAreTheBuiltInsWithGoogleFirst() {
    let s = Settings.defaults
    #expect(searchEngines(s).map(\.id) == builtInEngines.map(\.id))
    #expect(defaultSearchEngine(s).id == "google")
    #expect(searchUrlPrefix(s) == "https://www.google.com/search?q=%s")
  }

  @Test func theChosenEngineAndAnUnknownIdFallsBackToGoogle() {
    #expect(defaultSearchEngine(settings(["searchEngine": .string("duckduckgo")])).id == "duckduckgo")
    #expect(defaultSearchEngine(settings(["searchEngine": .string("gone")])).id == "google")
  }

  @Test func aLegacyCustomUrlGoesBeforeTheExtensionEngines() {
    let ext: SolaraModel.JSONValue = .array([
      .object([
        "profile": .string("p"), "extensionId": .string("e1"), "extensionName": .string("Ext"), "name": .string("One"), "keyword": .string("one"),
        "url": .string("https://one.example/?q=%s"), "isDefault": .bool(false),
      ])
    ])
    let custom: SolaraModel.JSONValue = .array([.object(["id": .string("c1"), "name": .string("Wiki"), "keyword": .string("wk"), "url": .string("https://wiki.example/?q=%s")])])
    let s = settings(["customSearchUrl": .string("https://legacy.example/?q=%s"), "extensionSearchEngines": ext, "customSearchEngines": custom, "searchEngine": .string("custom")])
    #expect(searchEngines(s).suffix(3).map(\.id) == ["c1", "custom", "extension:e1"])
    #expect(searchUrlPrefix(s) == "https://legacy.example/?q=%s")
    #expect(searchEngines(settings(["customSearchUrl": .string("https://no-placeholder.example/")])).count == builtInEngines.count)
  }

  @Test func aControllingExtensionWins() {
    let ext: SolaraModel.JSONValue = .array([
      .object(["extensionId": .string("e2"), "extensionName": .string("Two"), "name": .string("Two"), "keyword": .string("two"), "url": .string("https://two.example/?q=%s"), "isDefault": .bool(true)])
    ])
    let s = settings(["extensionSearchEngines": ext, "searchEngine": .string("bing")])
    #expect(controllingSearchExtension(s)?.extensionId == "e2")
    #expect(defaultSearchEngine(s).id == "extension:e2")
    #expect(searchUrlPrefix(s) == "https://two.example/?q=%s")
  }

  @Test func validationSeesEveryEngine() {
    let custom: SolaraModel.JSONValue = .array([.object(["id": .string("c1"), "name": .string("Wiki"), "keyword": .string("wk"), "url": .string("https://wiki.example/?q=%s")])])
    let s = settings(["customSearchEngines": custom])
    let input = EngineInput(name: "Again", keyword: "WK", url: "https://x.example/?q=%s")
    #expect(validateCustomEngine(s, input) == "“wk” is already used by another search engine.")
    #expect(validateCustomEngine(s, input, ignoreId: "c1") == nil)
  }
}
