import Foundation

public struct CalendarData: Sendable, Equatable {
  public var access: CalendarAuthorization = .notDetermined
  public var calendars: [SystemCalendar] = []
  public var events: [CalendarEvent] = []
  public var loading = false
  public var error: String?
  public var lastFetch: Double?

  public init() {}

  public var connected: Bool { access == .fullAccess || access == .fixture }
}

public struct CalendarFixture: Codable, Sendable, Equatable {
  public struct Event: Codable, Sendable, Equatable {
    public var id: String
    public var calendarId: String
    public var color: String
    public var title: String
    public var startInMinutes: Double
    public var durationMinutes: Double
    public var allDay: Bool
    public var location: String
    public var notes: String
    public var url: String
    public var cancelled: Bool
    public var declined: Bool
    public var organizer: CalendarParticipant?
    public var attendees: [CalendarParticipant]

    public func encode(to encoder: Encoder) throws {
      var c = encoder.container(keyedBy: CodingKeys.self)
      try c.encode(id, forKey: .id)
      try c.encode(calendarId, forKey: .calendarId)
      try c.encode(color, forKey: .color)
      try c.encode(title, forKey: .title)
      try c.encode(startInMinutes, forKey: .startInMinutes)
      try c.encode(durationMinutes, forKey: .durationMinutes)
      try c.encode(allDay, forKey: .allDay)
      try c.encode(location, forKey: .location)
      try c.encode(notes, forKey: .notes)
      try c.encode(url, forKey: .url)
      try c.encode(cancelled, forKey: .cancelled)
      try c.encode(declined, forKey: .declined)
      try c.encode(organizer, forKey: .organizer)
      try c.encode(attendees, forKey: .attendees)
    }
  }

  public var calendars: [SystemCalendar]
  public var events: [Event]

  public static let documentName = "calendar-fixture.json"
  public static let horizonMs: Double = 36 * 3_600_000

  public func resolved(launchedAt: Double) -> (calendars: [SystemCalendar], events: [CalendarEvent]) {
    let base = (launchedAt / 60_000).rounded(.down) * 60_000
    let events = self.events.map { e -> CalendarEvent in
      let start = base + e.startInMinutes * 60_000
      return CalendarEvent(
        id: e.id, occurrence: "\(e.id)@\(jsInteger(start))", calendarId: e.calendarId, color: e.color, title: e.title, start: start,
        end: start + e.durationMinutes * 60_000, allDay: e.allDay, location: e.location, notes: e.notes, url: e.url, cancelled: e.cancelled,
        declined: e.declined, organizer: e.organizer, attendees: e.attendees)
    }
    return (calendars, events)
  }
}

func jsInteger(_ value: Double) -> String {
  if value.rounded() == value, abs(value) < 1e21 { return String(Int64(value)) }
  return String(value)
}
