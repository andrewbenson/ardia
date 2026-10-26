import Foundation
import Testing

@testable import SolaraLive

func stubPR(_ id: String, _ number: Int, _ headRef: String, _ baseRef: String, stack: PullRequestStack? = nil) -> LiveItem {
  LiveItem(
    id: id, source: .github, url: "https://github.com/o/r/pull/\(number)", title: "PR \(number)", subtitle: "", icon: nil, updatedAt: 0,
    section: .authored, pr: PullRequestInfo(number: number, repo: "o/r", headRef: headRef, baseRef: baseRef, stack: stack))
}

@Suite struct FolderOptionsTests {
  static let savedBeforeOptions =
    #"{"folders":{"old":{"id":"old","profileId":"p","kind":"pullRequests","name":"PRs","icon":null,"collapsed":false,"sources":[],"filters":{"authored":true,"reviewRequests":true},"createdAt":0}},"folderOrder":["old"]}"#

  let rig = Rig(documents: [LiveState.documentName: FolderOptionsTests.savedBeforeOptions])
  var engine: LiveEngine { rig.engine }

  let stacked = [
    stubPR("a", 1, "one", "main", stack: PullRequestStack(id: "stack:a", position: 1, size: 2)),
    stubPR("b", 2, "two", "one", stack: PullRequestStack(id: "stack:a", position: 2, size: 2)),
    stubPR("c", 3, "three", "main"),
  ]

  func bitbucket(_ id: String) -> LiveItem {
    var item = stubPR(id, 1, "h-\(id)", "main")
    item.source = .bitbucket
    return item
  }

  func shown(_ id: String) async -> [String] { await engine.state.items[id]!.map(\.id) }

  @Test func withStacksGroupedAStackIsOneRowHoldingItsPullRequestsInOrder() {
    let rows = LiveRows.folderRows(id: "f", kind: .pullRequests, groupStacks: true, items: stacked, showAll: [:])
    let keys = rows.map { row -> String in
      if case .stack(_, _, _, let items) = row { return "stack:\(items.map(\.id).joined(separator: ","))" }
      return row.key
    }
    #expect(keys == ["stack:a,b", "c"])
  }

  @Test func withStacksUngroupedEachStackedPullRequestIsItsOwnRow() {
    let rows = LiveRows.folderRows(id: "f", kind: .pullRequests, groupStacks: false, items: stacked, showAll: [:])
    #expect(rows.map { "\($0.kind):\($0.key)" } == ["item:a", "item:b", "item:c"])
  }

  @Test func aFolderSavedBeforeTheseOptionsExistedLoadsWithStacksGroupedAndCompletedPullRequestsShown() async {
    #expect(await engine.state.folders["old"]!.groupStacks == true)
    #expect(await engine.state.folders["old"]!.showCompleted == true)
  }

  @Test func aHiddenPullRequestStaysOutOfTheFolderThroughLaterFetchesUntilAManualRefresh() async {
    let id = await engine.createFolder(profileId: "p", kind: .pullRequests, sources: [])
    await engine.applyFetch(id, stacked, gone: [:])
    await engine.update { $0.unread[id] = ["a", "c"] }
    await engine.hideItems(id, [stacked[0]])
    #expect(await shown(id) == ["b", "c"])
    #expect(await engine.state.unread[id] == ["c"], "hiding also clears the hidden row's unread pip")

    await engine.applyFetch(id, stacked, gone: [:])
    #expect(await shown(id) == ["b", "c"], "a fetch that still returns the hidden pull request keeps it out")

    let refreshing = await engine.manualRefresh(id)
    #expect(await shown(id).sorted() == ["a", "b", "c"], "a manual refresh shows hidden pull requests at once, before its fetch lands")
    #expect(await engine.state.hidden[id] == nil)
    await refreshing.value
    await engine.applyFetch(id, stacked, gone: [:])
    #expect(await shown(id) == ["a", "b", "c"], "and the next fetch that lists them keeps them")
  }

  @Test func hidingAPullRequestWhileItsMergePlaysKeepsItOutOfCompleted() async {
    let id = await engine.createFolder(profileId: "p", kind: .pullRequests, sources: [])
    await engine.applyFetch(id, stacked, gone: [:])
    await engine.applyFetch(id, stacked.filter { $0.id != "c" }, gone: ["c": .merged])
    await engine.hideItems(id, [stacked[2]])
    await engine.finishCompleting(id, ["c"])
    #expect(await engine.state.completed[id] == [])
    #expect(await engine.state.completing[id] == [])
  }

  @Test func everyHiddenPullRequestStaysHiddenHoweverManyAreHiddenBeforeAManualRefresh() async {
    let id = await engine.createFolder(profileId: "p", kind: .pullRequests, sources: [])
    let many = (0..<700).map { stubPR("x\($0)", $0, "h\($0)", "main") }
    await engine.applyFetch(id, many, gone: [:])
    for it in many { await engine.hideItems(id, [it]) }
    await engine.applyFetch(id, many, gone: [:])
    #expect(await engine.state.items[id] == [])
  }

  @Test func aHiddenPullRequestThatMergesStopsCountingAsHiddenOneThatOnlyDropsOutOfAFetchStaysHidden() async {
    let id = await engine.createFolder(profileId: "p", kind: .pullRequests, sources: [])
    await engine.applyFetch(id, stacked, gone: [:])
    await engine.hideItems(id, [stacked[1], stacked[2]])
    await engine.applyFetch(id, [stacked[0]], gone: ["c": .merged])
    #expect(await engine.state.hidden[id]!.map(\.id) == ["b"])
    #expect(await engine.state.completed[id] == [], "a pull request that merged while hidden doesn't show under Completed")
  }

  @Test func aManualRefreshWhoseFetchFailsKeepsThePullRequestsItUnhid() async {
    let id = await engine.createFolder(profileId: "p", kind: .pullRequests, sources: [.bitbucket])
    await engine.applyFetch(id, [bitbucket("x"), bitbucket("y")], gone: [:])
    await engine.hideItems(id, [bitbucket("x")])
    await engine.manualRefresh(id).value
    #expect(await engine.state.status[id]!.error?.source == .bitbucket, "the fetch failed: Bitbucket isn't connected in tests")
    #expect(await shown(id).sorted() == ["x", "y"])
  }

  @Test func aHiddenPullRequestThatDropsOutOfAFetchStaysHiddenWhileItsSourceCantSayItClosed() async {
    let id = await engine.createFolder(profileId: "p", kind: .pullRequests, sources: [.bitbucket])
    await engine.applyFetch(id, [bitbucket("x")], gone: [:])
    await engine.hideItems(id, [bitbucket("x")])
    await engine.updateFolder(id, FolderPatch(filters: LiveFilters(authored: false, reviewRequests: true)))
    await engine.refreshFolder(id).value
    #expect(await engine.state.hidden[id]!.map(\.id) == ["x"])
  }

  @Test func aManualRefreshDuringAnAutomaticOneKeepsWhatItUnhidWhenTheFetchFails() async {
    let id = await engine.createFolder(profileId: "p", kind: .pullRequests, sources: [.bitbucket])
    await engine.applyFetch(id, [bitbucket("x"), bitbucket("y")], gone: [:])
    await engine.hideItems(id, [bitbucket("x")])
    let automatic = await engine.refreshFolder(id)
    let manual = await engine.manualRefresh(id)
    await automatic.value
    await manual.value
    #expect(await shown(id).sorted() == ["x", "y"])
  }

  @Test func aRefreshDoesntAskWhetherPullRequestsItsFiltersLeaveOutHaveClosed() async {
    let id = await engine.createFolder(profileId: "p", kind: .pullRequests, sources: [.bitbucket])
    await engine.applyFetch(id, [bitbucket("x"), bitbucket("y")], gone: [:])
    await engine.hideItems(id, [bitbucket("x")])
    await engine.updateFolder(id, FolderPatch(filters: LiveFilters(authored: false, reviewRequests: true)))
    let asked = Locked<[String]>([])
    await engine.setResolveGone(.bitbucket) { _, items in
      asked.with { $0 += items.map(\.id) }
      return ["x": .merged, "y": .merged]
    }
    await engine.refreshFolder(id).value
    #expect(asked.current == [])
    #expect(await engine.state.hidden[id]!.map(\.id) == ["x"])
    #expect(await engine.state.completed[id] == [], "rows a filter turned off don't show up as completed")
  }

  @Test func aHiddenReviewRequestOnlyLeavesTheHiddenListWhenItClosedNotWhenItMayHaveBeenReviewed() async {
    let id = await engine.createFolder(profileId: "p", kind: .pullRequests, sources: [])
    var review = stubPR("r", 9, "h-r", "main")
    review.section = .review
    await engine.applyFetch(id, [review], gone: [:])
    await engine.hideItems(id, [review])
    await engine.applyFetch(id, [], gone: ["r": .reviewed])
    #expect(await engine.state.hidden[id]!.map(\.id) == ["r"])
  }

  @Test func aRefreshDoesntAskAboutHiddenPullRequestsFromASourceTheFolderNoLongerFetches() async {
    let id = await engine.createFolder(profileId: "p", kind: .pullRequests, sources: [.github, .bitbucket])
    await engine.applyFetch(id, [bitbucket("x")], gone: [:])
    await engine.hideItems(id, [bitbucket("x")])
    await engine.updateFolder(id, FolderPatch(sources: [.github]))
    let asked = Locked<[String]>([])
    await engine.setResolveGone(.bitbucket) { _, items in
      asked.with { $0 += items.map(\.id) }
      return ["x": .merged]
    }
    await engine.refreshFolder(id).value
    #expect(asked.current == [])
    #expect(await engine.state.hidden[id]!.map(\.id) == ["x"])
  }

  @Test func anOpenTabOfAHiddenPullRequestStaysOutOfTheFolderInsteadOfComingBackAsAStrayRow() async {
    let id = await engine.createFolder(profileId: "p", kind: .pullRequests, sources: [])
    await engine.applyFetch(id, stacked, gone: [:])
    await engine.hideItems(id, [stacked[0]])
    let shown = Set(await engine.state.items[id]!.map(\.id))
    let hidden = Set(await engine.state.hidden[id]!.map(\.id))
    #expect(LiveRows.liveTabPlace("a", shown: shown, hidden: hidden) == .hidden)
    #expect(LiveRows.liveTabPlace("b", shown: shown, hidden: hidden) == .row)
    #expect(
      LiveRows.liveTabPlace("gone", shown: shown, hidden: hidden) == .stray, "a tab whose pull request left the fetch still shows as its own row")
  }
}
