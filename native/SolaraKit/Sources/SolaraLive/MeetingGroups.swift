import Foundation

public struct MeetingBrowserSnapshot: Sendable, Equatable {
  public struct Group: Sendable, Equatable {
    public var id: String
    public var windowId: String
    public var tabIds: [String]

    public init(id: String, windowId: String, tabIds: [String]) {
      self.id = id
      self.windowId = windowId
      self.tabIds = tabIds
    }
  }

  public struct Tab: Sendable, Equatable {
    public var id: String
    public var url: String
    public var lastActiveAt: Double?
    public var playingAudio: Bool

    public init(id: String, url: String, lastActiveAt: Double? = nil, playingAudio: Bool = false) {
      self.id = id
      self.url = url
      self.lastActiveAt = lastActiveAt
      self.playingAudio = playingAudio
    }
  }

  public var groups: [String: Group]
  public var tabs: [String: Tab]
  public var activeTabByWindow: [String: String?]

  public init(groups: [String: Group], tabs: [String: Tab], activeTabByWindow: [String: String?]) {
    self.groups = groups
    self.tabs = tabs
    self.activeTabByWindow = activeTabByWindow
  }
}

public protocol LiveMeetingHost: Sendable {
  func meetingSnapshot() async -> MeetingBrowserSnapshot
  func closeGroup(_ groupId: String) async
}

public enum MeetingGroups {
  public static let fallbackTitle = "Meeting"
  public static let cleanupIdleMs: Double = 30 * 60_000
  public static let tickEvery: Double = 30_000

  public static func sameMeeting(
    _ groups: [MeetingGroup], browser: MeetingBrowserSnapshot, windowId: String, callUrl: String, occurrence: String?
  ) -> MeetingGroup? {
    guard let call = Meetings.meetingOf(callUrl) else { return nil }
    return groups.first { m in
      guard let g = browser.groups[m.groupId], g.windowId == windowId, m.endedAt == nil else { return false }
      if let o = m.occurrence, o == occurrence { return true }
      guard let callTab = browser.tabs[m.callTabId] else { return false }
      return Meetings.meetingOf(callTab.url)?.key == call.key
    }
  }

  public static func newGroup(groupId: String, callTabId: String, event: CalendarEvent?) -> MeetingGroup {
    let title = (event?.title.isEmpty ?? true) ? fallbackTitle : event!.title
    return MeetingGroup(
      groupId: groupId, callTabId: callTabId, occurrence: event?.occurrence, title: title, start: event?.start, end: event?.end, endedAt: nil)
  }

  public struct TickResult: Sendable, Equatable {
    public var state: [String: MeetingGroup]
    public var close: [String]
  }

  public static func tick(_ meetingGroups: [String: MeetingGroup], order: [String]? = nil, browser: MeetingBrowserSnapshot, now: Double)
    -> TickResult
  {
    var next = meetingGroups
    var close: [String] = []
    for id in order ?? meetingGroups.keys.sorted() {
      guard let m = meetingGroups[id] else { continue }
      guard let g = browser.groups[m.groupId] else {
        next[m.groupId] = nil
        continue
      }
      guard let endedAt = m.endedAt else {
        let callTab = browser.tabs[m.callTabId]
        let leftCall = callTab.map { Meetings.meetingOf($0.url) == nil } ?? true
        if let end = m.end, now >= end {
          next[m.groupId]?.endedAt = now
        } else if m.end == nil, leftCall {
          next[m.groupId]?.endedAt = now
        }
        continue
      }
      let active = browser.activeTabByWindow[g.windowId] ?? nil
      let busy = g.tabIds.contains { $0 == active || (browser.tabs[$0]?.playingAudio ?? false) }
      let lastUse = ([endedAt] + g.tabIds.map { browser.tabs[$0]?.lastActiveAt ?? 0 }).max()!
      if !busy, now - lastUse >= cleanupIdleMs {
        next[m.groupId] = nil
        close.append(m.groupId)
      }
    }
    return TickResult(state: next, close: close)
  }
}
