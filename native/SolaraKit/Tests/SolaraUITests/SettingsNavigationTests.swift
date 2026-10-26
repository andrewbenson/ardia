import Testing
@testable import SolaraUI

@MainActor
struct SettingsNavigationTests {
  @Test func goPushesTheCurrentPlaceAndClearsForward() {
    let nav = SettingsNavigation()
    nav.go(.tabs)
    nav.go(.appearance)
    nav.goBack()
    #expect(nav.canGoForward)
    nav.go(.privacy)
    #expect(nav.back.map(\.pane) == [.general, .tabs])
    #expect(nav.forward.isEmpty)
    #expect(nav.pane == .privacy)
  }

  @Test func goingToTheSamePlaceIsANoOp() {
    let nav = SettingsNavigation()
    nav.go(.general)
    #expect(nav.back.isEmpty)
    nav.go(.extensions, profileId: "p1")
    nav.go(.extensions, profileId: "p1")
    #expect(nav.back.count == 1)
    nav.go(.extensions, profileId: "p2")
    #expect(nav.back.count == 2)
  }

  @Test func backIsCappedAtThirty() {
    let nav = SettingsNavigation()
    for i in 0..<40 { nav.go(i.isMultiple(of: 2) ? .tabs : .search, detail: "\(i)") }
    #expect(nav.back.count == 30)
    #expect(nav.back.last?.detail == "38")
  }

  @Test func backAndForwardWalkTheHistory() {
    let nav = SettingsNavigation()
    nav.go(.tabs)
    nav.go(.search)
    nav.goBack()
    #expect(nav.pane == .tabs)
    #expect(nav.forward.map(\.pane) == [.search])
    nav.goBack()
    #expect(nav.pane == .general)
    #expect(!nav.canGoBack)
    nav.goBack()
    #expect(nav.pane == .general)
    nav.goForward()
    nav.goForward()
    #expect(nav.pane == .search)
    #expect(!nav.canGoForward)
  }

  @Test func replaceCollapsesAMatchingPreviousEntry() {
    let nav = SettingsNavigation()
    nav.go(.profiles)
    nav.go(.profiles, profileId: "a")
    nav.replace(profileId: nil)
    #expect(nav.place == SettingsPlace(pane: .profiles))
    #expect(nav.back.map(\.pane) == [.general])
    nav.go(.extensions, profileId: "x")
    nav.replace(profileId: "y")
    #expect(nav.back.last == SettingsPlace(pane: .profiles))
    #expect(nav.profileId == "y")
  }

  @Test func searchSubmitRevealsTheSelectedResult() {
    let index = SettingsIndex(appName: "Solara")
    let nav = SettingsNavigation()
    let search = SettingsSearchModel(index: index, liquidGlass: false)
    search.query = "trackers"
    search.moveSelection(5)
    search.moveSelection(-10)
    #expect(search.selected == 0)
    search.submit(navigation: nav) { pane, _ in pane == .extensions ? "p" : nil }
    #expect(nav.pane == .privacy)
    #expect(search.reveal == "privacy.blockTrackers")
    search.flashSetting("privacy.blockTrackers")
    #expect(search.reveal == nil)
    #expect(search.flash?.id == "privacy.blockTrackers")
    search.query = "x"
    #expect(search.selected == 0)
  }
}
