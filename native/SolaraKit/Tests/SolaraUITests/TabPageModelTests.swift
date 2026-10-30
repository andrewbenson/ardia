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
    #expect(m.issuedSeq == 1)
    #expect(m.issued(TabNavigationRequest(seq: 1, url: "https://a.test/", userInitiated: true), newTabShown: false, startedEarly: false).isEmpty)
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

  @Test func aNewNavigationBeforeTheFirstHandoffFollowStillLoads() {
    var m = fresh(handoff: 1)
    #expect(m.issued(TabNavigationRequest(seq: 2, url: "https://b.test/"), newTabShown: false, startedEarly: false) == [.load("https://b.test/", userInitiated: false)])
  }

  @Test func clearingNavigationAllowsItsSequenceToBeFollowedAgain() {
    var m = fresh()
    let nav = TabNavigationRequest(seq: 1, url: "https://a.test/")
    _ = m.issued(nav, newTabShown: false, startedEarly: false)
    #expect(m.issued(nil, newTabShown: false, startedEarly: false).isEmpty)
    #expect(m.issuedSeq == 1)
    #expect(m.issued(nav, newTabShown: false, startedEarly: false) == [.load(nav.url, userInitiated: false)])
  }

  @Test func aSameProfileMovePreservesTheSurvivingPage() {
    var m = fresh()
    _ = m.issued(TabNavigationRequest(seq: 1, url: "https://a.test/"), newTabShown: false, startedEarly: false)
    m.moved(sameProfile: true)
    #expect(m.issued(TabNavigationRequest(seq: 2, url: "https://moved.test/"), newTabShown: true, startedEarly: false).isEmpty)
    #expect(m.issued(TabNavigationRequest(seq: 3, url: "https://next.test/"), newTabShown: false, startedEarly: false) == [.load("https://next.test/", userInitiated: false)])
  }

  @Test func aProfileChangeDoesNotTreatANavigationAsArrived() {
    var m = fresh()
    _ = m.issued(TabNavigationRequest(seq: 1, url: "https://a.test/"), newTabShown: false, startedEarly: false)
    m.moved(sameProfile: false)
    #expect(m.issued(TabNavigationRequest(seq: 2, url: "https://next.test/"), newTabShown: false, startedEarly: false) == [.load("https://next.test/", userInitiated: false)])
  }

  @Test func aHandoffWithoutANavigationDoesNotSwallowTheFirstRequest() {
    var m = fresh(nil)
    #expect(m.issued(TabNavigationRequest(seq: 1, url: "https://first.test/"), newTabShown: false, startedEarly: false) == [.load("https://first.test/", userInitiated: false)])
  }

  @Test func anUntouchedBlankIsAcceptedForAnAboutTarget() {
    var m = fresh(TabNavigationRequest(seq: 1, url: "about:blank"))
    #expect(m.reported(TabNavigationReport(url: "", committedInitial: true), TabPageContext()).contains(.navigated(url: "", title: "", isLoading: false, canGoBack: false, canGoForward: false)))
    #expect(m.pending == nil)
  }

  @Test func anOldStyleAdoptedOpenerBlankIsNotSuppressed() {
    var m = fresh(adopted: "https://opener.test/")
    #expect(m.reported(TabNavigationReport(url: ""), TabPageContext(openedByAdoption: true)).contains(.navigated(url: "", title: "", isLoading: false, canGoBack: false, canGoForward: false)))
  }

  @Test func aDownloadRestoresOnlyAChangedCommittedURL() {
    var m = fresh()
    #expect(m.downloadNavigation(committedUrl: "https://before.test/", skipped: false, context: TabDownloadContext(currentUrl: "https://file.test/")) == [.stopLoading, .updateURL("https://before.test/")])
    #expect(m.pending == nil)
    #expect(m.downloadNavigation(committedUrl: "https://before.test/", skipped: false, context: TabDownloadContext(currentUrl: "https://before.test/")) == [.stopLoading])
  }

  @Test func anUncommittedDownloadClosesAnAdoptedOrOpenerTab() {
    var m = fresh()
    for adopted in [false, true] {
      #expect(m.downloadNavigation(committedUrl: nil, skipped: false, context: TabDownloadContext(hasOtherProfileTab: true, hasOpener: !adopted, hasAdoptId: adopted)) == [.stopLoading, .closeTab])
    }
  }

  @Test func downloadCloseGuardsReturnToNewTab() {
    var m = fresh()
    let contexts = [
      TabDownloadContext(hasOtherProfileTab: false, hasOpener: true),
      TabDownloadContext(hasOtherProfileTab: true),
      TabDownloadContext(hasOtherProfileTab: true, hasOpener: true, wasNewTab: true),
      TabDownloadContext(hasOtherProfileTab: true, hasOpener: true, canGoBack: true),
    ]
    for context in contexts {
      #expect(m.downloadNavigation(committedUrl: "", skipped: false, context: context) == [.stopLoading, .resetToNewTab])
    }
    #expect(m.downloadNavigation(committedUrl: nil, skipped: true, context: TabDownloadContext(hasOtherProfileTab: true, hasOpener: true)) == [.stopLoading, .resetToNewTab])
  }

  @Test func aDownloadForAMissingTabOnlyClearsPending() {
    var m = fresh()
    #expect(m.downloadNavigation(committedUrl: nil, skipped: false, context: TabDownloadContext(tabExists: false)).isEmpty)
    #expect(m.pending == nil)
  }

  @Test func discardResetsTheNewTabOriginAndKeepsTheWakeTarget() {
    var m = fresh(newTab: true)
    #expect(m.discarded("https://sleep.test/") == [.discarded])
    #expect(m.pending == "https://sleep.test/")
    #expect(m.reported(TabNavigationReport(url: "", committedInitial: true), TabPageContext()) == [.markLoading])
    #expect(!m.reported(TabNavigationReport(url: "https://sleep.test/"), TabPageContext()).contains(.backToNewTab))
    #expect(m.ready(muted: false) == [.ready])
    #expect(m.ready(muted: true) == [.ready, .setMuted(true)])
  }

  @Test func aChromeWindowCloseCarriesItsWindowFlagUnlessQuitting() {
    let m = fresh()
    #expect(m.windowClosed(withWindow: true, isQuitting: false) == [.closeTabs(windowClosedByChrome: true)])
    #expect(m.windowClosed(withWindow: false, isQuitting: false) == [.closeTabs(windowClosedByChrome: false)])
    #expect(m.windowClosed(withWindow: true, isQuitting: true).isEmpty)
  }
}
