import AppKit
import Testing

@testable import SolaraUI

@MainActor
@Suite struct SidebarLiveCardTests {
  private let look: [String: Any] = [
    "dark": true, "panel": "#262626", "panelBorder": "#404040", "shadowOpacity": 0.5,
    "textPrimary": "rgba(255,255,255,0.86)", "textSecondary": "rgba(255,255,255,0.585)", "divider": "rgba(255,255,255,0.1)",
    "rowHover": "rgba(255,255,255,0.08)", "accent": "#4C8DFF", "toolbarHover": "rgba(255,255,255,0.1)",
    "toolbarPressed": "rgba(255,255,255,0.18)", "urlPill": "rgba(255,255,255,0.06)", "success": "#3FB950",
    "failure": "#F85149", "pending": "#D29922", "draft": "#8B949E", "conflict": "#D29922", "ciTrack": "rgba(255,255,255,0.08)",
  ]

  private func pullRequest(failing: Int) -> [String: Any] {
    [
      "id": "live|f|1", "url": "https://github.com/o/r/pull/1", "title": "Fix the thing", "width": 300,
      "anchor": [8, 100, 184, 34], "profileId": "default", "look": look,
      "pr": [
        "author": "octocat", "place": "o/r #1", "draft": false, "success": 3, "pending": 1, "failure": failing,
        "summary": ["symbol": "xmark.circle.fill", "tone": "failure", "text": "\(failing) failing"],
        "failing": (0..<failing).map { ["name": "check \($0)", "url": "https://ci/\($0)"] },
        "conflicting": true, "review": ["symbol": "checkmark.circle.fill", "tone": "success", "text": "Approved"],
        "comments": "2 comments", "additions": 10, "deletions": 4, "files": "3 files",
      ] as [String: Any],
    ]
  }

  @Test func decodesAPullRequestAndADocument() throws {
    let pr = try #require(SidebarLiveCardState.decode(pullRequest(failing: 5)))
    #expect(pr.pr?.failing.count == 5)
    #expect(pr.anchorRect == CGRect(x: 8, y: 100, width: 184, height: 34))
    let doc = try #require(SidebarLiveCardState.decode([
      "id": "live|f|2", "url": "https://docs.google.com/d/1", "title": "Plan", "width": 280, "anchor": [8, 140, 184, 34],
      "profileId": "default", "look": look, "doc": ["icon": NSNull(), "direct": false, "meta": "Doc · Drive", "edited": "Edited 2h ago by Sam"],
    ] as [String: Any]))
    #expect(doc.pr == nil)
    #expect(doc.doc?.meta == "Doc · Drive")
  }

  @Test func takesItsWidthAndAHeightFromItsContent() throws {
    let card = SidebarLiveCardView(favicons: nil)
    card.set(try #require(SidebarLiveCardState.decode(pullRequest(failing: 1))))
    #expect(card.frame.width == 300)
    let short = card.frame.height
    #expect(short > 100)
    card.set(try #require(SidebarLiveCardState.decode(pullRequest(failing: 3))))
    #expect(card.frame.height > short)
  }
}
