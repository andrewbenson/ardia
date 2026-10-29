import Foundation

public struct CalendarParticipant: Codable, Sendable, Equatable {
  public enum Status: String, Codable, Sendable { case accepted, declined, tentative, pending }
  public var name: String
  public var email: String
  public var status: Status?
  public var me: Bool

  public init(name: String, email: String, status: Status, me: Bool) {
    self.name = name
    self.email = email
    self.status = status
    self.me = me
  }
}

public struct SystemCalendar: Codable, Sendable, Equatable {
  public enum AccountType: String, Codable, Sendable { case local, exchange, calDAV, subscribed, birthdays, other }
  public var id: String
  public var title: String
  public var color: String
  public var account: String
  public var accountType: AccountType
  public var owned: Bool

  public init(id: String, title: String, color: String, account: String, accountType: AccountType, owned: Bool) {
    self.id = id
    self.title = title
    self.color = color
    self.account = account
    self.accountType = accountType
    self.owned = owned
  }
}

public struct CalendarEvent: Codable, Sendable, Equatable {
  public var id: String
  public var occurrence: String
  public var calendarId: String
  public var color: String
  public var title: String
  public var start: Double
  public var end: Double
  public var allDay: Bool
  public var location: String
  public var notes: String
  public var url: String
  public var cancelled: Bool
  public var declined: Bool
  public var organizer: CalendarParticipant?
  public var attendees: [CalendarParticipant]

  public init(
    id: String, occurrence: String, calendarId: String, color: String = "", title: String, start: Double, end: Double, allDay: Bool = false,
    location: String = "", notes: String = "", url: String = "", cancelled: Bool = false, declined: Bool = false,
    organizer: CalendarParticipant? = nil, attendees: [CalendarParticipant] = []
  ) {
    self.id = id
    self.occurrence = occurrence
    self.calendarId = calendarId
    self.color = color
    self.title = title
    self.start = start
    self.end = end
    self.allDay = allDay
    self.location = location
    self.notes = notes
    self.url = url
    self.cancelled = cancelled
    self.declined = declined
    self.organizer = organizer
    self.attendees = attendees
  }

  public func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode(id, forKey: .id)
    try c.encode(occurrence, forKey: .occurrence)
    try c.encode(calendarId, forKey: .calendarId)
    try c.encode(color, forKey: .color)
    try c.encode(title, forKey: .title)
    try c.encode(start, forKey: .start)
    try c.encode(end, forKey: .end)
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

public enum MeetingProvider: String, Codable, Sendable {
  case meet, zoom, teams, webex, other
}

public struct MeetingKey: Codable, Sendable, Equatable {
  public var provider: MeetingProvider
  public var key: String
}

public struct JoinLink: Codable, Sendable, Equatable {
  public var url: String
  public var provider: MeetingProvider
}

public struct AlertLead: Sendable, Equatable {
  public var value: String
  public var title: String
  public var minutes: Int?
}

public enum Meetings {
  static let minute: Double = 60_000

  struct Parsed {
    var host: String
    var path: String
  }

  static func parse(_ url: String) -> Parsed? {
    guard let c = URLComponents(string: url), let scheme = c.scheme, !scheme.isEmpty else { return nil }
    let host = (c.percentEncodedHost ?? "").lowercased()
    var path = c.percentEncodedPath
    if path.isEmpty, ["http", "https", "ws", "wss", "ftp", "file"].contains(scheme.lowercased()) { path = "/" }
    return Parsed(host: host, path: path)
  }

  static func host(_ url: String) -> String { parse(url)?.host ?? "" }
  static func path(_ url: String) -> String { parse(url)?.path ?? "" }

  static func regex(_ pattern: String, _ options: NSRegularExpression.Options = []) -> NSRegularExpression {
    try! NSRegularExpression(pattern: pattern, options: options)
  }

  static func firstGroup(_ re: NSRegularExpression, _ text: String) -> String? {
    let ns = text as NSString
    guard let m = re.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)), m.numberOfRanges > 1,
      m.range(at: 1).location != NSNotFound
    else { return nil }
    return ns.substring(with: m.range(at: 1))
  }

  static func matches(_ re: NSRegularExpression, _ text: String) -> Bool {
    re.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)) != nil
  }

  static let outlookHost = regex(#"^outlook\.(live|office|office365)\.com$"#)
  static let meetCode = regex(#"^/([a-z]{3,4}-[a-z]{3,4}-[a-z]{3,4})(?![A-Za-z0-9_])"#, [.caseInsensitive])
  static let zoomId = regex(#"^/(?:j|s|w|wc(?:/join)?|my)/([A-Za-z0-9_.-]+)"#)
  static let zoomWebJoin = regex(#"^/wc/([0-9]+)/join"#)
  static let webexPath = regex(#"^/(meet|join|[A-Za-z0-9_-]+/j\.php)"#)
  static let urlPattern = regex(#"https?://[^\s<>"'`)\]]+"#)
  static let trailingPunctuation = regex(#"[.,;:]+$"#)
  static let noise: [NSRegularExpression] = [
    #"(^|\.)support\.google\.com$"#, #"(^|\.)accounts\.google\.com$"#, #"^tel\."#, #"(^|\.)aka\.ms$"#, #"(^|\.)go\.microsoft\.com$"#,
    #"(^|\.)microsoft\.com$"#, #"(^|\.)zoom\.us$"#, #"(^|\.)zoom\.com$"#, #"(^|\.)apple\.com$"#, #"^calendar\.google\.com$"#,
    #"^meet\.google\.com$"#,
  ].map { regex($0) }

  static func isTeamsHost(_ h: String) -> Bool { h == "teams.microsoft.com" || h == "teams.cloud.microsoft" || h == "teams.live.com" }

  public static func isCalendarUrl(_ url: String) -> Bool {
    let h = host(url)
    let p = path(url)
    if h == "calendar.google.com" || h == "calendar.notion.so" || h == "calendar.proton.me" || h == "app.fantastical.com" { return true }
    if matches(outlookHost, h) || h == "outlook.cloud.microsoft" { return p.hasPrefix("/calendar") }
    if isTeamsHost(h) { return !isMeetingUrl(url) }
    if h == "www.icloud.com" || h == "icloud.com" { return p.hasPrefix("/calendar") }
    return false
  }

  public static func meetingOf(_ url: String) -> MeetingKey? {
    let h = host(url)
    let p = path(url)
    if h == "meet.google.com" {
      guard let code = firstGroup(meetCode, p) else { return nil }
      return MeetingKey(provider: .meet, key: "meet:\(code.lowercased())")
    }
    if h == "zoom.us" || h.hasSuffix(".zoom.us") || h == "zoom.com" || h.hasSuffix(".zoom.com") {
      guard let id = firstGroup(zoomId, p) ?? firstGroup(zoomWebJoin, p) else { return nil }
      return MeetingKey(provider: .zoom, key: "zoom:\(id.lowercased())")
    }
    if isTeamsHost(h) {
      if p.hasPrefix("/l/meetup-join/") || p.hasPrefix("/meet/") || (p.hasPrefix("/v2/") && url.contains("meetup-join")) {
        return MeetingKey(provider: .teams, key: "teams:\(JS.utf16Prefix(JS.decodeURIComponent(p), 160))")
      }
      return nil
    }
    if h.hasSuffix(".webex.com"), matches(webexPath, p) { return MeetingKey(provider: .webex, key: "webex:\(h)\(p)") }
    return nil
  }

  public static func isMeetingUrl(_ url: String) -> Bool { meetingOf(url) != nil }

  static func links(_ text: String) -> [String] {
    let ns = text as NSString
    return urlPattern.matches(in: text, range: NSRange(location: 0, length: ns.length))
      .map { m -> String in
        let found = ns.substring(with: m.range)
        let fns = found as NSString
        return trailingPunctuation.stringByReplacingMatches(in: found, range: NSRange(location: 0, length: fns.length), withTemplate: "")
      }
      .uniqued()
  }

  public static func joinLink(url: String?, location: String?, notes: String?) -> JoinLink? {
    for text in [url, location, notes] {
      for link in links(text ?? "") {
        if let m = meetingOf(link) { return JoinLink(url: link, provider: m.provider) }
      }
    }
    return nil
  }

  public static func joinLink(_ event: CalendarEvent) -> JoinLink? {
    joinLink(url: event.url, location: event.location, notes: event.notes)
  }

  public static func relatedLinks(url: String?, location: String?, notes: String?) -> [String] {
    let join = joinLink(url: url, location: location, notes: notes)?.url
    return links("\(url ?? "") \(location ?? "") \(notes ?? "")").filter { u in
      if u == join || isMeetingUrl(u) { return false }
      let h = host(u)
      return !h.isEmpty && !noise.contains { matches($0, h) }
    }
  }

  public static func relatedLinks(_ event: CalendarEvent) -> [String] {
    relatedLinks(url: event.url, location: event.location, notes: event.notes)
  }

  public static func isMeeting(_ e: CalendarEvent) -> Bool { !e.allDay && !e.cancelled && !e.declined }

  public static func currentOrNext(_ events: [CalendarEvent], now: Double) -> CalendarEvent? {
    let meetings = events.filter(isMeeting).filter { $0.end > now }
    if let current = meetings.filter({ $0.start <= now }).stableSorted(by: { $0.start > $1.start }).first { return current }
    return meetings.stableSorted { $0.start < $1.start }.first
  }

  public static func eventForCall(_ events: [CalendarEvent], url: String, now: Double) -> CalendarEvent? {
    guard let key = meetingOf(url)?.key else { return nil }
    let matches = events.filter { isMeeting($0) && meetingOf(joinLink($0)?.url ?? "")?.key == key }
    return matches.stableSorted { abs($0.start - now) < abs($1.start - now) }.first
  }

  public static func badgeText(_ events: [CalendarEvent], now: Double, withinMs: Double = 60 * 60_000) -> String? {
    guard let e = currentOrNext(events, now: now) else { return nil }
    if e.start <= now { return "Now" }
    let ms = e.start - now
    if ms > withinMs { return nil }
    let min = Int((ms / minute).rounded(.up))
    return min >= 60 ? "\(min / 60)h" : "\(min)m"
  }

  static func jsRound(_ x: Double) -> Int { Int((x + 0.5).rounded(.down)) }

  public static func relativeTime(_ at: Double, now: Double) -> String {
    let min = jsRound((at - now) / minute)
    if min == 0 { return "Now" }
    let a = abs(min)
    let text = a >= 60 ? "\(a / 60) hr\(a % 60 != 0 ? " \(a % 60) min" : "")" : "\(a) min"
    return min > 0 ? "in \(text)" : "\(text) ago"
  }

  public static func ago(_ at: Double, now: Double) -> String {
    let min = Int((max(0, now - at) / minute).rounded(.down))
    if min < 1 { return "just now" }
    if min < 60 { return "\(min) min ago" }
    let hr = min / 60
    if hr < 24 { return "\(hr) hr ago" }
    let days = hr / 24
    return days == 1 ? "yesterday" : "\(days) days ago"
  }

  public static func timeRemaining(_ end: Double, now: Double) -> String {
    let min = Int(((end - now) / minute).rounded(.up))
    if min <= 0 { return "Ending now" }
    return min >= 60 ? "\(min / 60) hr \(min % 60) min left" : "\(min) min left"
  }

  public static let wiggleMarksMinutes = [5, 2]

  static func displayName(_ p: CalendarParticipant) -> String {
    if !p.name.isEmpty { return p.name }
    let local = p.email.split(separator: "@", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
    return local.isEmpty ? "Guest" : local
  }

  public static func attendeesLabel(_ attendees: [CalendarParticipant]) -> String {
    let names = attendees.filter { !$0.me }.map(displayName)
    switch names.count {
    case 0: return ""
    case 1: return names[0]
    case 2: return "\(names[0]) and \(names[1])"
    default: return "\(names[0]), \(names[1]) and \(names.count - 2) more"
    }
  }

  public static func guestsLabel(_ attendees: [CalendarParticipant]) -> String {
    attendees.count == 1 ? "1 guest" : "\(attendees.count) guests"
  }

  public static func timeRange(start: Double, end: Double, locale: Locale = .current, timeZone: TimeZone = .current) -> String {
    let style = Date.FormatStyle(locale: locale, timeZone: timeZone).hour(.defaultDigits(amPM: .abbreviated)).minute(.twoDigits)
    let fmt = { (ms: Double) in Date(timeIntervalSince1970: ms / 1000).formatted(style) }
    return "\(fmt(start)) – \(fmt(end))"
  }

  public static func joinTitle(_ provider: MeetingProvider?) -> String {
    switch provider {
    case .meet: "Join with Google Meet"
    case .zoom: "Join with Zoom"
    case .teams: "Join Microsoft Teams Meeting"
    default: "Join"
    }
  }

  public static let alertLeads: [AlertLead] = [
    AlertLead(value: "never", title: "Never", minutes: nil),
    AlertLead(value: "start", title: "At Meeting Start", minutes: 0),
    AlertLead(value: "1", title: "One Minute Before", minutes: 1),
    AlertLead(value: "2", title: "Two Minutes Before", minutes: 2),
    AlertLead(value: "3", title: "Three Minutes Before", minutes: 3),
    AlertLead(value: "5", title: "Five Minutes Before", minutes: 5),
    AlertLead(value: "10", title: "Ten Minutes Before", minutes: 10),
  ]

  public static func dueAlerts(_ events: [CalendarEvent], now: Double, leadMinutes: Int, dismissed: Set<String>) -> [CalendarEvent] {
    events
      .filter(isMeeting)
      .filter { e in
        !dismissed.contains(e.occurrence) && now >= e.start - Double(leadMinutes) * minute && now < min(e.end, e.start + 5 * minute)
      }
      .stableSorted { $0.start < $1.start }
  }
}
