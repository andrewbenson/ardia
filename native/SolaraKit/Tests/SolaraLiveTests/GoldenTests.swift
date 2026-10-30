import Foundation
import Testing

@testable import SolaraLive

@Suite struct GoldenTests {
  var golden: [String: Any] { Fixture.golden }
  func cases(_ key: String) -> [[String: Any]] { golden[key] as! [[String: Any]] }

  @Test func githubMappingMatchesJSForEveryFilter() {
    let fixture = Fixture.decode(GithubResponse.self, "github.json")
    for c in cases("mapGithub") {
      let filters = decoded(LiveFilters.self, c["filters"]!)
      #expect(canonical(encoding: GitHub.mapGithub(fixture, filters: filters)) == canonical(c["items"]!), "\(filters)")
      #expect(GitHub.detailIds(fixture, filters: filters) == c["detailIds"] as! [String])
    }
  }

  @Test func stacksMatchJS() {
    for c in cases("withStacks") {
      let items = decoded([LiveItem].self, c["items"]!)
      #expect(canonical(encoding: GitHub.withStacks(items)) == canonical(c["out"]!))
    }
  }

  @Test func folderRowsMatchJS() {
    for c in cases("rows") {
      let folder = c["folder"] as! [String: Any]
      let items = decoded([LiveItem].self, c["items"]!)
      let rows = LiveRows.folderRows(
        id: folder["id"] as! String, kind: LiveFolderKind(rawValue: folder["kind"] as! String)!, groupStacks: folder["groupStacks"] as! Bool,
        items: items, showAll: c["showAll"] as! [String: Bool], page: c["page"] as! Int)
      #expect(canonical(encoding: rows) == canonical(c["rows"]!), "\(folder) \(c["showAll"]!) \(c["page"]!)")
    }
  }

  @Test func checkSummariesAndBadgesMatchJS() {
    for c in cases("checks") {
      let checks = decoded([PullRequestCheck].self, c["checks"]!)
      let summary = GitHub.summarizeChecks(checks)
      if c["summary"] is NSNull {
        #expect(summary == nil)
      } else {
        #expect(canonical(encoding: summary) == canonical(c["summary"]!))
      }
    }
    for c in cases("badges") {
      let pr = decoded(PullRequestInfo.self, c["pr"]!)
      #expect(GitHub.prBadge(pr)?.rawValue == c["badge"] as? String)
    }
  }

  @Test func documentMappersMatchJS() {
    let docs = golden["docs"] as! [String: Any]
    let search = Fixture.decode(NotionSearch.self, "notion-search.json")
    let users = Fixture.decode(NotionUsers.self, "notion-users.json")
    #expect(canonical(encoding: Documents.mapNotion(search, users: users, workspace: "Acme")) == canonical(docs["notion"]!))
    #expect(canonical(encoding: Documents.mapNotion(search, users: nil, workspace: nil)) == canonical(docs["notionNoUsers"]!))
    #expect(canonical(encoding: Documents.mapDrive(Fixture.decode(DriveFiles.self, "drive-files.json"))) == canonical(docs["drive"]!))

  }

  @Test func meetingDetectionMatchesJS() {
    for c in cases("urlCases") {
      let url = c["url"] as! String
      let meeting = Meetings.meetingOf(url)
      if c["meetingOf"] is NSNull {
        #expect(meeting == nil, "\(url)")
      } else {
        #expect(canonical(encoding: meeting) == canonical(c["meetingOf"]!), "\(url)")
      }
      #expect(Meetings.isCalendarUrl(url) == c["isCalendarUrl"] as! Bool, "\(url)")
      #expect(Meetings.isMeetingUrl(url) == c["isMeetingUrl"] as! Bool, "\(url)")
    }
    for c in cases("links") {
      let e = c["event"] as! [String: Any]
      let url = e["url"] as? String, location = e["location"] as? String, notes = e["notes"] as? String
      let join = Meetings.joinLink(url: url, location: location, notes: notes)
      #expect((join.map { canonical(encoding: $0) } ?? "null") == canonical(c["joinLink"]!))
      #expect(Meetings.relatedLinks(url: url, location: location, notes: notes) == c["relatedLinks"] as! [String], "\(e)")
    }
  }

  @Test func calendarTimelineMatchesJS() {
    let calendar = golden["calendar"] as! [String: Any]
    let events = decoded([CalendarEvent].self, calendar["events"]!)
    for t in calendar["timeline"] as! [[String: Any]] {
      let now = t["now"] as! Double
      let label = "at \(t["minutes"]!) min"
      #expect(Meetings.currentOrNext(events, now: now)?.occurrence == t["currentOrNext"] as? String, "\(label)")
      #expect(Meetings.badgeText(events, now: now) == t["badgeText"] as? String, "\(label)")
      #expect(Meetings.badgeText(events, now: now, withinMs: 30 * 60_000) == t["badgeText30"] as? String, "\(label)")
      let dismissed = Set(t["dismissed"] as! [String])
      for (lead, expected) in t["dueAlerts"] as! [String: [String]] {
        #expect(
          Meetings.dueAlerts(events, now: now, leadMinutes: Int(lead)!, dismissed: dismissed).map(\.occurrence) == expected, "\(label) lead \(lead)")
      }
      let calls = ["https://meet.google.com/abc-defg-hij", "https://acme.zoom.us/j/81234567890", "https://zoom.us/j/1"]
      #expect(calls.map { Meetings.eventForCall(events, url: $0, now: now)?.occurrence } == (t["eventForCall"] as! [Any]).map { $0 as? String })
    }
    for f in calendar["eventFacts"] as! [[String: Any]] {
      let e = events.first { $0.occurrence == f["occurrence"] as! String }!
      #expect((Meetings.joinLink(e).map { canonical(encoding: $0) } ?? "null") == (f["joinLink"] is NSNull ? "null" : canonical(f["joinLink"]!)))
      #expect(Meetings.relatedLinks(e) == f["relatedLinks"] as! [String])
      #expect(Meetings.attendeesLabel(e.attendees) == f["attendeesLabel"] as! String)
      #expect(Meetings.guestsLabel(e.attendees) == f["guestsLabel"] as! String)
      #expect(Meetings.isMeeting(e) == f["isMeeting"] as! Bool)
    }
    for c in cases("attendeeCases") {
      let attendees = decoded([CalendarParticipant].self, c["attendees"]!)
      #expect(Meetings.attendeesLabel(attendees) == c["attendeesLabel"] as! String)
      #expect(Meetings.guestsLabel(attendees) == c["guestsLabel"] as! String)
    }
  }

  @Test func timeTextMatchesJS() {
    let base = (golden["calendar"] as! [String: Any])["base"] as! Double
    for c in cases("time") {
      let delta = c["delta"] as! Double
      #expect(Meetings.relativeTime(base + delta, now: base) == c["relativeTime"] as! String, "\(delta)")
      #expect(Meetings.ago(base - delta, now: base) == c["ago"] as! String, "\(delta)")
      #expect(Meetings.timeRemaining(base + delta, now: base) == c["timeRemaining"] as! String, "\(delta)")
    }
  }

  @Test func errorTextMatchesJS() {
    for c in cases("errorText") {
      let kind = LiveErrorKind(rawValue: c["kind"] as! String)!
      let source = LiveSourceId(rawValue: c["source"] as! String)!
      #expect(LiveEngine.errorText(kind, source: source) == c["text"] as! String)
    }
  }

  @Test func dateParsingAndURIEncodingMatchJS() {
    for c in cases("dates") {
      #expect(JS.dateParse(c["text"] as! String) == c["ms"] as! Double, "\(c["text"]!)")
    }
    for c in cases("uri") {
      #expect(JS.encodeURIComponent(c["text"] as! String) == c["encoded"] as! String)
    }
  }

  @Test func storeActionsReplayToTheStateJSPersists() async throws {
    let replay = golden["stateReplay"] as! [String: Any]
    let rig = Rig()
    let engine = rig.engine
    for step in replay["replay"] as! [[String: Any]] {
      let args = step["args"] as! [Any]
      switch step["op"] as! String {
      case "createFolder":
        await engine.createFolder(
          profileId: args[0] as! String, kind: LiveFolderKind(rawValue: args[1] as! String)!,
          sources: args.count > 2 ? decoded([LiveSourceId].self, args[2]) : nil)
      case "applyFetch":
        await engine.applyFetch(
          args[0] as! String, decoded([LiveItem].self, args[1]), gone: decoded([String: CompletionState].self, args[2]), now: args[3] as? Double,
          quiet: args.count > 4 ? Set(args[4] as! [String]) : [])
      case "hideItems": await engine.hideItems(args[0] as! String, decoded([LiveItem].self, args[1]))
      case "markRead": await engine.markRead(args[0] as! String, args.count > 1 ? args[1] as? [String] : nil)
      case "finishCompleting": await engine.finishCompleting(args[0] as! String, args[1] as! [String])
      case "updateFolder":
        let patch = args[1] as! [String: Any]
        await engine.updateFolder(
          args[0] as! String,
          FolderPatch(
            name: patch["name"] as? String, groupStacks: patch["groupStacks"] as? Bool,
            after: patch.keys.contains("after") ? .some(patch["after"] as? String) : .none))
      case "arrangeFolders":
        await engine.arrangeFolders((args[0] as! [[String: Any]]).map { FolderPlacement(id: $0["id"] as! String, after: $0["after"] as? String) })
      case "setAccount":
        await engine.setAccount(
          LiveSourceId(rawValue: args[0] as! String)!, args[1] is NSNull ? nil : decoded(LiveAccount.self, args[1]))
      case "updateConfig":
        let patch = args[0] as! [String: String]
        await engine.updateConfig(ConfigPatch(githubClientId: patch["githubClientId"], googleClientId: patch["googleClientId"]))
      case "updateCalendarSettings":
        let patch = args[0] as! [String: Any]
        await engine.updateCalendarSettings(
          CalendarSettingsPatch(
            alertLead: patch["alertLead"] as? String, hiddenCalendarIds: patch["hiddenCalendarIds"] as? [String], prompted: patch["prompted"] as? Bool))
      case "dismissAlert":
        let occurrence = args[0] as! String
        await engine.update { $0.dismissAlert(occurrence) }
      case "setMeetingGroup":
        await engine.setMeetingGroup(args[0] is NSNull ? nil : decoded(MeetingGroup.self, args[0]), groupId: args.count > 1 ? args[1] as? String : nil)
      case let op: Issue.record("unknown op \(op)")
      }
    }
    let state = await engine.state
    let expected = try JSONSerialization.jsonObject(with: Data((replay["persisted"] as! String).utf8))
    #expect(canonical(try JSONSerialization.jsonObject(with: Data(try state.persistedJSON().utf8))) == canonical(expected))
    #expect(canonical(encoding: state.status) == canonical(replay["status"]!))
    #expect(canonical(encoding: state.completing) == canonical(replay["completing"]!))
    let reloaded = LiveState.load(replay["persisted"] as? String)
    #expect(reloaded.persistedPart == state.persistedPart)
  }
}
