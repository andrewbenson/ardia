import Foundation
import Testing

@testable import SolaraLive

final class FakeMeetingHost: LiveMeetingHost, @unchecked Sendable {
  let browser: Locked<MeetingBrowserSnapshot>
  let closed = Locked<[String]>([])
  init(_ browser: MeetingBrowserSnapshot) { self.browser = Locked(browser) }
  func meetingSnapshot() async -> MeetingBrowserSnapshot { browser.current }
  func closeGroup(_ groupId: String) async { closed.with { $0.append(groupId) } }
}

@Suite struct EngineTests {
  func lastFetch(_ rig: Rig, _ id: String) async -> Double? { await rig.engine.state.status[id]?.lastFetch }

  @Test func foldersRefreshAfterLaunchThenOnTheThirtySecondGridOnceTheyAreDue() async {
    let rig = Rig()
    let start = rig.clock.now()
    let prs = await rig.engine.createFolder(profileId: "p", kind: .pullRequests, sources: [])
    let docs = await rig.engine.createFolder(profileId: "p", kind: .documents, sources: [])
    await rig.engine.start()
    await settle()
    await rig.clock.advance(by: LiveEngine.firstRefreshDelayMs - 1)
    #expect(await lastFetch(rig, prs) == nil)
    await rig.clock.advance(by: 1)
    let first = start + LiveEngine.firstRefreshDelayMs
    #expect(await lastFetch(rig, prs) == first)
    #expect(await lastFetch(rig, docs) == first)
    let prsDue = ((first + 180_000) / 30_000).rounded(.up) * 30_000
    await rig.clock.advance(by: prsDue - 1 - rig.clock.now())
    #expect(await lastFetch(rig, prs) == first)
    await rig.clock.advance(by: 1)
    #expect(await lastFetch(rig, prs) == prsDue)
    #expect(await lastFetch(rig, docs) == first, "documents wait ten minutes")
    let docsDue = ((first + 600_000) / 30_000).rounded(.up) * 30_000
    await rig.clock.advance(by: docsDue - rig.clock.now())
    #expect(await lastFetch(rig, docs) == docsDue)
    await rig.engine.stop()
  }

  @Test func focusRefreshesFoldersOlderThanAMinuteAndANudgeWaitsThreeSecondsAtMostEveryTwenty() async {
    let rig = Rig()
    let id = await rig.engine.createFolder(profileId: "p", kind: .pullRequests, sources: [])
    await rig.engine.refreshFolder(id).value
    let fetched = rig.clock.now()
    await rig.clock.advance(by: 59_999)
    await rig.engine.windowFocused()
    await settle()
    #expect(await lastFetch(rig, id) == fetched)
    await rig.clock.advance(by: 1)
    await rig.engine.windowFocused()
    await settle()
    #expect(await lastFetch(rig, id) == rig.clock.now())

    let nudgedAt = rig.clock.now()
    await rig.engine.liveTabDeactivated(folderId: id)
    await rig.clock.advance(by: 2999)
    #expect(await lastFetch(rig, id) == nudgedAt)
    await rig.clock.advance(by: 1)
    #expect(await lastFetch(rig, id) == nudgedAt + 3000)
    await rig.engine.liveTabDeactivated(folderId: id)
    await rig.clock.advance(by: 10_000)
    #expect(await lastFetch(rig, id) == nudgedAt + 3000, "a second nudge inside twenty seconds is dropped")
    await rig.clock.advance(by: 7000)
    await rig.engine.liveTabDeactivated(folderId: id)
    await rig.clock.advance(by: 3000)
    #expect(await lastFetch(rig, id) == nudgedAt + 23_000)
  }

  @Test func changesSaveLiveJSONAfterEightHundredMillisecondsOfQuiet() async throws {
    let rig = Rig()
    let start = rig.clock.now()
    await rig.engine.createFolder(profileId: "p", kind: .pullRequests, sources: [])
    await rig.clock.advance(by: 500)
    await rig.engine.setExpandedStack("stack:x", true)
    await rig.clock.advance(by: 700)
    await rig.engine.setShowAll("f:authored", true)
    await rig.clock.advance(by: 99)
    #expect(rig.documents.writes.current == 0)
    await rig.clock.advance(by: 1)
    #expect(rig.documents.writes.current == 1, "showAll isn't persisted, so it doesn't restart the wait")
    let saved = LiveState.load(rig.documents.read(LiveState.documentName))
    #expect(saved.expandedStacks == ["stack:x": true])
    #expect(saved.showAll == [:])
    #expect(saved.folderOrder == ["lf-\(String(Int(start), radix: 36))-1"])
  }

  @Test func statusTextCountsMinutesAndHiddenRows() async {
    let rig = Rig()
    let id = await rig.engine.createFolder(profileId: "p", kind: .pullRequests, sources: [])
    #expect(await rig.engine.statusText(id) == "Loading…")
    await rig.engine.applyFetch(id, [stubPR("a", 1, "h", "main")], gone: [:])
    let now = rig.clock.now()
    #expect(await rig.engine.statusText(id, now: now + 59_999) == "Updated just now")
    #expect(await rig.engine.statusText(id, now: now + 60_000) == "Updated 1 min ago")
    #expect(await rig.engine.statusText(id, now: now + 7_200_000) == "Updated 2 hr ago")
    await rig.engine.hideItems(id, [stubPR("a", 1, "h", "main")])
    #expect(await rig.engine.statusText(id, now: now) == "Updated just now · 1 hidden until you refresh")
    let begun = await rig.engine.refreshFolder(id)
    #expect(await rig.engine.statusText(id, now: now) == "Updating… · 1 hidden until you refresh")
    await begun.value
  }

  @Test func newFoldersUseConnectedSourcesAndRemovedProfilesTakeTheirFolders() async {
    let rig = Rig()
    await rig.engine.setAccount(.bitbucket, LiveAccount(login: "b", name: nil, avatar: nil, connectedAt: 0))
    let a = await rig.engine.newProfileLiveFolder(profileId: "keep", kind: .pullRequests)
    let b = await rig.engine.newProfileLiveFolder(profileId: "gone", kind: .documents)
    #expect(await rig.engine.state.folders[a]?.sources == [.bitbucket])
    #expect(await rig.engine.state.folders[b]?.sources == [.notion])
    #expect(await rig.engine.state.folders[a]?.name == "Pull Requests")
    await rig.engine.profilesChanged(existing: ["keep"])
    #expect(await rig.engine.state.folderOrder == [a])
    await rig.engine.deleteLiveFolder(a)
    #expect(await rig.engine.state.folders.isEmpty)
  }

  @Test func theChangeStreamDeliversTheLatestSnapshot() async {
    let rig = Rig()
    let stream = await rig.engine.changes()
    var iterator = stream.makeAsyncIterator()
    #expect(await iterator.next()?.live.folderOrder == [])
    let id = await rig.engine.createFolder(profileId: "p", kind: .documents, sources: [])
    #expect(await iterator.next()?.live.folderOrder == [id])
  }

  @Test func theCalendarReadsVisibleCalendarsFromStartOfDayForThirtySixHours() async {
    let rig = Rig()
    let work = SystemCalendar(id: "work", title: "Work", color: "#1", account: "a", accountType: .calDAV, owned: true)
    let home = SystemCalendar(id: "home", title: "Home", color: "#2", account: "a", accountType: .calDAV, owned: true)
    rig.calendar.calendarList.with { $0 = [work, home] }
    let now = rig.clock.now()
    rig.calendar.eventList.with {
      $0 = [
        CalendarEvent(id: "late", occurrence: "late@1", calendarId: "work", title: "Late", start: now + 7_200_000, end: now + 9_000_000),
        CalendarEvent(id: "home", occurrence: "home@1", calendarId: "home", title: "Home", start: now, end: now + 60_000),
        CalendarEvent(id: "early", occurrence: "early@1", calendarId: "work", title: "Early", start: now + 60_000, end: now + 120_000),
      ]
    }
    await rig.engine.start()
    await settle()
    #expect(await rig.engine.calendarData.access == .notDetermined)
    #expect(await rig.engine.connectCalendar() == true)
    #expect(await rig.engine.calendarData.events.map(\.id) == ["home", "early", "late"])
    let asked = rig.calendar.asked.current.last!
    #expect(asked.0 == (Calendar.current.startOfDay(for: Date(timeIntervalSince1970: now / 1000)).timeIntervalSince1970 * 1000).rounded())
    #expect(asked.1 == now + 36 * 3_600_000)
    await rig.engine.setCalendarHidden("home", hidden: true)
    await settle()
    #expect(await rig.engine.calendarData.events.map(\.id) == ["early", "late"])
    #expect(await rig.engine.state.calendar.hiddenCalendarIds == ["home"])
    let calls = rig.calendar.asked.current.count
    let next = ((rig.clock.now() / 300_000).rounded(.down) + 1) * 300_000
    await rig.clock.advance(by: next - rig.clock.now() - 1)
    #expect(rig.calendar.asked.current.count == calls)
    await rig.clock.advance(by: 1)
    #expect(rig.calendar.asked.current.count == calls + 1, "connected calendars refresh every five minutes")
    await rig.engine.stop()
  }

  @Test func meetingAlertsShowAtTheLeadAndNotifyOnlyWhileTheAppIsInactive() async {
    let rig = Rig(documents: [CalendarFixture.documentName: Fixture.text("calendar-fixture.json")], environment: LiveEnvironment(calendarFixture: true))
    let base = (rig.clock.now() / 60_000).rounded(.down) * 60_000
    let design = "design@\(jsInteger(base + 2 * 60_000))"
    await rig.engine.start()
    await settle()
    #expect(await rig.engine.calendarData.access == .fixture)
    #expect(await rig.engine.meetingAlert == nil)
    await rig.engine.appResignedActive()
    await rig.clock.advance(by: base + 60_000 - rig.clock.now() + 10_000)
    #expect(await rig.engine.meetingAlert?.occurrence == design)
    let posted = rig.notifier.posted.current
    #expect(posted.count == 1)
    #expect(posted.first?.id == "meeting:\(design)")
    #expect(posted.first?.title == "Design review: Live folders")
    #expect(posted.first?.body.hasPrefix("Starts in 1 min") == true)
    #expect(posted.first?.body.hasSuffix(" · Join with Google Meet") == true)
    await rig.clock.advance(by: 20_000)
    #expect(rig.notifier.posted.current.count == 1, "each occurrence notifies once")
    await rig.engine.dismissAlert(rig.engine.meetingAlert!)
    #expect(await rig.engine.meetingAlert == nil)
    #expect(rig.notifier.removed.current == ["meeting:\(design)"])
    #expect(await rig.engine.state.dismissedAlerts == [design])
    await rig.engine.updateCalendarSettings(CalendarSettingsPatch(alertLead: "never"))
    #expect(await rig.engine.alertEvent(now: base + 2 * 60_000) == nil)
    await rig.engine.stop()
  }

  @Test func meetingGroupsEndWithTheirEventAndCloseAfterHalfAnHourIdle() async {
    let rig = Rig()
    let now = rig.clock.now()
    let host = FakeMeetingHost(
      MeetingBrowserSnapshot(
        groups: ["g": .init(id: "g", windowId: "w", tabIds: ["call", "doc"]), "lone": .init(id: "lone", windowId: "w", tabIds: ["x"])],
        tabs: ["call": .init(id: "call", url: "https://meet.google.com/abc-defg-hij", lastActiveAt: now), "doc": .init(id: "doc", url: "https://docs")],
        activeTabByWindow: ["w": "other"]))
    await rig.engine.setMeetingGroup(MeetingGroup(groupId: "g", callTabId: "call", occurrence: "o", title: "T", start: now, end: now + 60_000, endedAt: nil))
    await rig.engine.setMeetingGroup(MeetingGroup(groupId: "lone", callTabId: "gone", occurrence: nil, title: "M", start: nil, end: nil, endedAt: nil))
    await rig.engine.setMeetingGroup(MeetingGroup(groupId: "stale", callTabId: "c", occurrence: nil, title: "M", start: nil, end: nil, endedAt: nil))
    await rig.engine.start(meetingHost: host)
    await settle()
    await rig.clock.advance(by: 30_000)
    var groups = await rig.engine.state.meetingGroups
    #expect(groups["stale"] == nil, "a group the browser no longer has is forgotten")
    #expect(groups["lone"]?.endedAt != nil, "a group without an end time ends when its call tab leaves the call")
    #expect(groups["g"]?.endedAt == nil)
    await rig.clock.advance(by: 60_000)
    groups = await rig.engine.state.meetingGroups
    let ended = groups["g"]!.endedAt!
    #expect(ended >= now + 60_000)
    await rig.clock.advance(by: ended + MeetingGroups.cleanupIdleMs + 30_000 - rig.clock.now())
    #expect(Set(host.closed.current) == ["g", "lone"])
    #expect(await rig.engine.state.meetingGroups.isEmpty)
    await rig.engine.stop()
  }

  @Test func aBusyMeetingGroupIsNotClosed() {
    let browser = MeetingBrowserSnapshot(
      groups: ["g": .init(id: "g", windowId: "w", tabIds: ["a", "b"])],
      tabs: ["a": .init(id: "a", url: "https://x"), "b": .init(id: "b", url: "https://y", playingAudio: true)], activeTabByWindow: ["w": nil])
    let groups = ["g": MeetingGroup(groupId: "g", callTabId: "a", occurrence: nil, title: "M", start: nil, end: 0, endedAt: 0)]
    #expect(MeetingGroups.tick(groups, browser: browser, now: 1e12).close == [])
    var quiet = browser
    quiet.tabs["b"]?.playingAudio = false
    #expect(MeetingGroups.tick(groups, browser: quiet, now: 1e12).close == ["g"])
    quiet.activeTabByWindow["w"] = "a"
    #expect(MeetingGroups.tick(groups, browser: quiet, now: 1e12).close == [])
    #expect(
      MeetingGroups.sameMeeting(
        [MeetingGroup(groupId: "g", callTabId: "a", occurrence: "o", title: "M", start: nil, end: nil, endedAt: nil)], browser: browser, windowId: "w",
        callUrl: "https://meet.google.com/abc-defg-hij", occurrence: "o")?.groupId == "g")
    #expect(MeetingGroups.newGroup(groupId: "n", callTabId: "t", event: nil).title == "Meeting")
  }
}
