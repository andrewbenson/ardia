import Foundation
import Testing

@testable import SolaraLive

@Suite struct CalendarReplicaTests {
  @Test func calendarAndAlertUseOneReplicaRevision() async throws {
    let rig = Rig()
    rig.calendar.access.with { $0 = .fullAccess }
    let now = rig.clock.now()
    let event = CalendarEvent(id: "standup", occurrence: "standup@1", calendarId: "work", title: "Standup", start: now, end: now + 60_000)
    rig.calendar.calendarList.with { $0 = [SystemCalendar(id: "work", title: "Work", color: "#123456", account: "A", accountType: .local, owned: true)] }
    rig.calendar.eventList.with { $0 = [event] }
    await rig.engine.refreshCalendar().value
    await rig.engine.checkAlerts()
    let wire = try await rig.engine.currentReplica()
    let calendar = try LiveJSON.decode(CalendarDataWire.self, from: wire.calendarJSON)
    let alert = try LiveJSON.decode(CalendarEvent?.self, from: wire.meetingAlertJSON)
    #expect(calendar.events == [event])
    #expect(alert == event)
    let revision = await rig.engine.revision
    #expect(wire.revision == revision)
  }

  @Test func meetingSnapshotBoxReturnsLatestBrowserStateAndSignalsClose() async {
    let box = MeetingBrowserSnapshotBox()
    let snapshot = MeetingBrowserSnapshot(groups: ["g": .init(id: "g", windowId: "w", tabIds: ["t"])], tabs: ["t": .init(id: "t", url: "https://meet.google.com/abc-defg-hij")], activeTabByWindow: ["w": "t"])
    box.replace(snapshot)
    #expect(await box.meetingSnapshot() == snapshot)
    let decoded = try! LiveJSON.decode(MeetingBrowserSnapshot.self, from: #"{"groups":{"g":{"id":"g","windowId":"w","tabIds":["t"]}},"tabs":{"t":{"id":"t","url":"https://meet.google.com/abc-defg-hij","lastActiveAt":null,"playingAudio":false}},"activeTabByWindow":{"w":null}}"#)
    box.replace(decoded)
    let active = (await box.meetingSnapshot())?.activeTabByWindow["w"] ?? nil
    #expect(active == nil)
    let closed = Locked<[String]>([])
    box.setCloseGroup { groupId in closed.with { $0.append(groupId) } }
    await box.closeGroup("g")
    #expect(closed.current == ["g"])
  }

  @Test func fixtureRefreshNeverUsesCalendarProvider() async {
    let rig = Rig(documents: [CalendarFixture.documentName: Fixture.text("calendar-fixture.json")], environment: LiveEnvironment(calendarFixture: true))
    await rig.engine.refreshCalendar().value
    #expect(await rig.engine.calendarData.access == .fixture)
    #expect(rig.calendar.asked.current.isEmpty)
    #expect(rig.calendar.access.current == .notDetermined)
  }

  @Test func pinnedCalendarOfferCannotWriteOverAnUnreadableDocument() async throws {
    let rig = Rig(documents: [LiveState.documentName: "not json"])
    let command = try LiveJSON.decode(LiveCommand.self, from: #"{"name":"offerAlertsForPinnedTab","payload":{"url":"https://calendar.google.com/"}}"#)
    await #expect(throws: LiveError.self) { _ = try await rig.engine.perform(command) }
    #expect(await rig.engine.state.calendar.prompted == false)
  }

}

@Suite struct CalendarFixtureShapeTests {
  @Test func aFixtureAttendeeWithoutAStatusDecodesAsJSReadsIt() throws {
    let text = ##"{"calendars":[{"id":"work","title":"Work","color":"#3478F6","account":"Fixture","accountType":"local","owned":true}],"events":[{"id":"standup","calendarId":"work","color":"#3478F6","title":"Standup","startInMinutes":3,"durationMinutes":15,"allDay":false,"location":"","notes":"","url":"","cancelled":false,"declined":false,"organizer":null,"attendees":[{"name":"Ada","email":"ada@example.com","me":false}]}]}"##
    let resolved = try LiveJSON.decode(CalendarFixture.self, from: text).resolved(launchedAt: 0)
    #expect(resolved.events.first?.attendees.first?.status == nil)
  }
}
