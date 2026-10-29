import Foundation
import SolaraLive
import Testing
@testable import SolaraUI

@Suite struct LiveSettingsMappingTests {
  @Test func foldersFollowOrderAndKeepOnlyPublishedFields() {
    var state = LiveState()
    let first = LiveFolder(id: "first", profileId: "p1", kind: .pullRequests, name: "First", sources: [.github], groupStacks: false, showCompleted: true, createdAt: 1)
    let second = LiveFolder(id: "second", profileId: "p2", kind: .documents, name: "Second", sources: [.notion], groupStacks: true, showCompleted: false, createdAt: 2)
    state.folders = [first.id: first, second.id: second]
    state.folderOrder = [second.id, "missing", first.id]
    state.hidden[second.id] = []
    state.hidden[first.id] = [LiveItem(id: "hidden", source: .github, url: "https://example.com", title: "Hidden", subtitle: "", updatedAt: 1)]
    state.status[first.id] = FolderStatus(state: .error, lastFetch: 1_700_000_000_000, error: FolderError(kind: .rateLimited, message: "private", source: .github))
    state.accounts[.github] = LiveAccount(login: "octocat", name: "Mona", avatar: "private-avatar", connectedAt: 42)
    state.config = LiveConfig(githubClientId: "client", bitbucketUser: "user", confluenceSite: "site", confluenceEmail: "mail", googleClientId: "google")
    state.config.extra["private"] = .string("ignored")

    let mapped = LiveSettingsMapping.folders(state, mocked: true)
    #expect(mapped.folders.map(\.id) == ["second", "first"])
    #expect(mapped.folders.map(\.hiddenCount) == [0, 1])
    #expect(mapped.folders[0].groupStacks && !mapped.folders[0].showCompleted)
    #expect(mapped.folders[1].status == LiveFolderStatus(state: .error, lastFetch: Date(timeIntervalSince1970: 1_700_000_000), error: LiveFolderError(kind: .rateLimited, source: .github)))
    #expect(mapped.accounts[.github] == LiveAccount(login: "octocat", name: "Mona", avatar: nil, connectedAt: 0))
    #expect(mapped.config.githubClientId == "client")
    #expect(mapped.config.bitbucketUser == "user")
    #expect(mapped.config.confluenceSite == "site")
    #expect(mapped.config.confluenceEmail == "mail")
    #expect(mapped.config.googleClientId == "google")
    #expect(mapped.config.extra.isEmpty)
    #expect(mapped.mocked)
    #expect(!LiveSettingsMapping.folders(state, mocked: false).mocked)
  }

  @Test func calendarKeepsAccessListAndOptions() {
    var state = LiveState()
    state.calendar = CalendarSettings(alertLead: "5", alertCondition: .activeOnly, showPreview: false, showTimeToNext: false, hiddenCalendarIds: ["home"], prompted: true)
    var data = CalendarData()
    data.access = .fixture
    data.calendars = [SystemCalendar(id: "home", title: "Home", color: "#123456", account: "iCloud", accountType: .local, owned: true)]

    let mapped = LiveSettingsMapping.calendar(state, data: data)
    #expect(mapped.access == .fixture)
    #expect(mapped.calendars == [SystemCalendarInfo(id: "home", title: "Home", color: "#123456", account: "iCloud", owned: true)])
    #expect(mapped.options == LiveCalendarOptions(alertLead: "5", alertCondition: "activeOnly", showPreview: false, showTimeToNext: false, hiddenCalendarIds: ["home"]))
  }
}
