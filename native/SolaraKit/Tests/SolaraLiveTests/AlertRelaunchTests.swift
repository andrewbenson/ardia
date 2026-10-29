import Foundation
import Testing

@testable import SolaraLive

@Suite struct AlertRelaunchTests {
  @Test func aMeetingNotifiedBeforeARelaunchIsNotNotifiedAgainAfterIt() async throws {
    let source = Rig(documents: [CalendarFixture.documentName: Fixture.text("calendar-fixture.json")], environment: LiveEnvironment(calendarFixture: true))
    await source.engine.start()
    await settle()
    let fixture = await source.engine.calendarData
    await source.engine.stop()
    let rig = Rig()
    rig.calendar.access.with { $0 = .fullAccess }
    rig.calendar.calendarList.with { $0 = fixture.calendars }
    rig.calendar.eventList.with { $0 = fixture.events }
    let base = (rig.clock.now() / 60_000).rounded(.down) * 60_000
    await rig.engine.start()
    await settle()
    await rig.engine.appResignedActive()
    await rig.clock.advance(by: base + 60_000 - rig.clock.now() + 10_000)
    #expect(rig.notifier.posted.current.count == 1)
    try await rig.engine.flush()
    await rig.engine.stop()
    let relaunched = LiveEngine(effects: rig.engine.effects)
    await relaunched.start()
    await settle()
    await relaunched.appResignedActive()
    await rig.clock.advance(by: 10_000)
    #expect(await relaunched.meetingAlert != nil)
    #expect(rig.notifier.posted.current.count == 1, "the relaunched app doesn't notify the same occurrence again")
    await relaunched.stop()
  }

  func dueRig() async -> (Rig, Double) {
    let source = Rig(documents: [CalendarFixture.documentName: Fixture.text("calendar-fixture.json")], environment: LiveEnvironment(calendarFixture: true))
    await source.engine.start()
    await settle()
    let fixture = await source.engine.calendarData
    await source.engine.stop()
    let rig = Rig()
    rig.calendar.access.with { $0 = .fullAccess }
    rig.calendar.calendarList.with { $0 = fixture.calendars }
    rig.calendar.eventList.with { $0 = fixture.events }
    return (rig, (rig.clock.now() / 60_000).rounded(.down) * 60_000)
  }

  @Test func theNotifiedMarkIsSavedAsSoonAsTheNotificationPosts() async throws {
    let (rig, base) = await dueRig()
    await rig.engine.start()
    await settle()
    await rig.engine.appResignedActive()
    await rig.clock.advance(by: base + 60_000 - rig.clock.now() + 10_000)
    #expect(rig.notifier.posted.current.count == 1)
    let saved = LiveState.load(rig.documents.read(LiveState.documentName))
    #expect(saved.notifiedAlerts.count == 1, "a force quit right after posting can't lose the mark")
    await rig.engine.stop()
  }

  @Test func aFailedPostIsRetriedInsteadOfMarkedNotified() async throws {
    let (rig, base) = await dueRig()
    rig.notifier.failing.with { $0 = true }
    await rig.engine.start()
    await settle()
    await rig.engine.appResignedActive()
    await rig.clock.advance(by: base + 60_000 - rig.clock.now() + 10_000)
    #expect(await rig.engine.state.notifiedAlerts.isEmpty)
    rig.notifier.failing.with { $0 = false }
    await rig.clock.advance(by: 10_000)
    #expect(rig.notifier.posted.current.count == 1)
    await rig.engine.stop()
  }
}

@Suite struct MeetingBridgeTests {
  @Test func noSnapshotYetMeansNoCleanup() async {
    let box = MeetingBrowserSnapshotBox()
    #expect(await box.meetingSnapshot() == nil)
    let group = MeetingGroup(groupId: "g", callTabId: "t", occurrence: nil, title: "Call", start: nil, end: nil, endedAt: nil)
    let rig = Rig()
    await rig.engine.setMeetingGroup(group)
    await rig.engine.start(jobs: [.meetings], meetingHost: box)
    await rig.engine.meetingTick()
    #expect(await rig.engine.state.meetingGroups["g"] != nil)
    await rig.engine.stop()
  }

  @Test func aCloseSentWhileJSIsAwayIsDeliveredWhenItReturns() async {
    let box = MeetingBrowserSnapshotBox()
    await box.closeGroup("g")
    let got = Locked<[String]>([])
    box.setCloseGroup { id in got.with { $0.append(id) } }
    #expect(got.current == ["g"])
  }
}
