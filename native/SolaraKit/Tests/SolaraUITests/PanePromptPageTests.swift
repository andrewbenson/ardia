import Testing
@testable import SolaraUI

@Suite struct PanePromptPageTests {
  private func take(_ page: inout PanePromptPage, _ name: String, _ payload: [String: Any]) -> Bool { page.take(name, payload) }

  @Test func crashShowsUntilThePageChanges() {
    var page = PanePromptPage()
    #expect(take(&page, "onNavigationChange", ["url": "https://a.test/x#one"]))
    #expect(take(&page, "onCrashed", ["reason": "test"]))
    #expect(page.sadMode == .crashed)
    #expect(!take(&page, "onNavigationChange", ["url": "https://a.test/x#two"]))
    #expect(page.sadMode == .crashed)
    #expect(take(&page, "onNavigationChange", ["url": "https://b.test/"]))
    #expect(page.sadMode == nil)
  }

  @Test func hangComesAndGoes() {
    var page = PanePromptPage()
    #expect(take(&page, "onUnresponsive", [:]))
    #expect(page.sadMode == .unresponsive)
    #expect(take(&page, "onResponsive", [:]))
    #expect(page.sadMode == nil)
  }

  @Test func crashReplacesHangAndANewPageClearsBoth() {
    var page = PanePromptPage()
    _ = page.take("onUnresponsive", [:])
    _ = page.take("onCrashed", [:])
    #expect(page == { var p = PanePromptPage(); p.crashed = true; return p }())
    #expect(take(&page, "onPageCreated", ["engine": "chromium"]))
    #expect(page.sadMode == nil)
  }

  @Test func untouchedInitialDocumentCountsAsBlank() {
    var page = PanePromptPage()
    _ = page.take("onNavigationChange", ["url": "https://a.test/"])
    _ = page.take("onCrashed", [:])
    _ = page.take("onNavigationChange", ["url": "https://a.test/", "initialDocumentAccessed": true, "committedInitial": true])
    #expect(page.sadMode == nil)
    #expect(page.pageKey == "about:blank")
  }

  @Test func otherEventsChangeNothing() {
    var page = PanePromptPage()
    #expect(!take(&page, "onTitleChange", ["title": "x"]))
  }
}
