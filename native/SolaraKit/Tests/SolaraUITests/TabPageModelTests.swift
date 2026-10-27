import Testing
@testable import SolaraUI

struct TabPageModelTests {
  func fresh(_ nav: TabNavigationRequest? = TabNavigationRequest(seq: 1, url: "https://a.test/"), handoff: Int? = nil, webkit: Bool = false, newTab: Bool = false, adopted: String? = nil) -> TabPageModel {
    TabPageModel(navigation: nav, adoptedUrl: adopted, handoffSeq: handoff, webkitWithoutHandoff: webkit, wasNewTab: newTab)
  }

  @Test func eachIssuedNavigationLoadsOnce() {
    var m = fresh()
    #expect(m.issued(TabNavigationRequest(seq: 1, url: "https://a.test/", userInitiated: true), newTabShown: false, startedEarly: false) == [.load("https://a.test/", userInitiated: true)])
    #expect(m.pending == "https://a.test/")
  }

  @Test func aHandedOffViewDoesNotReloadItsNavigation() {
    var m = fresh(handoff: 1)
    #expect(m.issued(TabNavigationRequest(seq: 1, url: "https://a.test/"), newTabShown: false, startedEarly: false).isEmpty)
    #expect(m.issued(TabNavigationRequest(seq: 2, url: "https://b.test/"), newTabShown: false, startedEarly: false) == [.load("https://b.test/", userInitiated: false)])
  }

  @Test func webKitLoadsItsFirstNavigationOnCreate() {
    var m = fresh(webkit: true)
    #expect(m.issued(TabNavigationRequest(seq: 1, url: "https://a.test/"), newTabShown: true, startedEarly: false) == [.clearNewTabShown])
  }

  @Test func anEarlyStartedNavigationIsNotLoadedAgain() {
    var m = fresh()
    #expect(m.issued(TabNavigationRequest(seq: 1, url: "https://a.test/"), newTabShown: false, startedEarly: true).isEmpty)
  }

  @Test func aPrewarmedPageAdoptsWhatItShowsAndSkipsThatNavigation() {
    var m = fresh(nil)
    #expect(m.reported(TabNavigationReport(url: "https://x.test/", title: "X"), TabPageContext(prewarmOnly: true)) == [
      .adoptNavigation("https://x.test/"), .navigated(url: "https://x.test/", title: "X", isLoading: false, canGoBack: false, canGoForward: false),
    ])
    #expect(m.issued(TabNavigationRequest(seq: 1, url: "https://x.test/"), newTabShown: false, startedEarly: false).isEmpty)
    #expect(m.reported(TabNavigationReport(url: "about:blank"), TabPageContext(prewarmOnly: true)).isEmpty)
  }

  @Test func theBlankBeforeTheTargetOnlyMarksLoading() {
    var m = fresh()
    _ = m.issued(TabNavigationRequest(seq: 1, url: "https://a.test/"), newTabShown: false, startedEarly: false)
    #expect(m.reported(TabNavigationReport(url: "", committedInitial: true), TabPageContext(navigationUrl: "https://a.test/")) == [.markLoading])
    #expect(m.pending == "https://a.test/")
  }

  @Test func theNewTabPageStaysWhileItsUrlIsShown() {
    var m = fresh()
    #expect(m.reported(TabNavigationReport(url: "https://a.test/", title: "A"), TabPageContext(newTabShownUrl: "https://a.test/")) == [.keepNewTabShown(title: "A")])
    #expect(m.reported(TabNavigationReport(url: "https://b.test/", title: "B"), TabPageContext(newTabShownUrl: "https://a.test/")) == [
      .clearNewTabShown, .navigated(url: "https://b.test/", title: "B", isLoading: false, canGoBack: false, canGoForward: false),
    ])
  }

  @Test func aTabOpenedFromTheNewTabPageCanGoBackToIt() {
    var m = fresh(newTab: true)
    #expect(m.reported(TabNavigationReport(url: "https://a.test/"), TabPageContext()).first == .backToNewTab)
  }

  @Test func leavingAPageIsReportedOnlyWhenThePageChanges() {
    var m = fresh()
    _ = m.reported(TabNavigationReport(url: "https://a.test/p"), TabPageContext())
    #expect(!m.reported(TabNavigationReport(url: "https://a.test/p#x"), TabPageContext()).contains(.leftPage(from: "https://a.test/p", to: "https://a.test/p#x")))
    #expect(m.reported(TabNavigationReport(url: "https://b.test/"), TabPageContext()).last == .leftPage(from: "https://a.test/p", to: "https://b.test/"))
  }

  @Test func anAccessedInitialDocumentReadsAsBlank() {
    var m = fresh(nil)
    #expect(m.reported(TabNavigationReport(url: "https://opener.test/", initialDocumentAccessed: true, committedInitial: true), TabPageContext()).first == .navigated(url: "about:blank", title: "", isLoading: false, canGoBack: false, canGoForward: false))
  }

  @Test func aLoadErrorDropsThePendingTarget() {
    var m = fresh()
    _ = m.issued(TabNavigationRequest(seq: 1, url: "https://a.test/"), newTabShown: false, startedEarly: false)
    m.loadFailed()
    #expect(m.pending == nil)
  }
}
