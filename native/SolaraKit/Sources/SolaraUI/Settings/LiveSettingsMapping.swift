import Foundation
import SolaraLive

public enum LiveSettingsMapping {
  public static func folders(_ state: LiveState, mocked: Bool) -> LiveFoldersState {
    let folders = state.folderOrder.compactMap { id -> LiveFolderSummary? in
      guard let folder = state.folders[id] else { return nil }
      let status = state.status[id].map {
        LiveFolderStatus(
          state: LiveFolderFetchState(rawValue: $0.state.rawValue)!,
          lastFetch: $0.lastFetch.map { Date(timeIntervalSince1970: $0 / 1000) },
          error: $0.error.map { LiveFolderError(kind: $0.kind, source: $0.source) }
        )
      }
      return LiveFolderSummary(
        id: folder.id, profileId: folder.profileId, kind: folder.kind, name: folder.name, sources: folder.sources,
        groupStacks: folder.groupStacks, showCompleted: folder.showCompleted, status: status, hiddenCount: state.hidden[id]?.count ?? 0
      )
    }
    let accounts = state.accounts.mapValues { LiveAccount(login: $0.login, name: $0.name, avatar: nil, connectedAt: 0) }
    let config = state.config
    return LiveFoldersState(
      folders: folders, accounts: accounts,
      config: LiveConfig(
        githubClientId: config.githubClientId, bitbucketUser: config.bitbucketUser, confluenceSite: config.confluenceSite,
        confluenceEmail: config.confluenceEmail, googleClientId: config.googleClientId
      ),
      mocked: mocked
    )
  }

  public static func calendar(_ state: LiveState, data: CalendarData) -> CalendarPaneState {
    let calendars = data.calendars.map {
      SystemCalendarInfo(id: $0.id, title: $0.title, color: $0.color, account: $0.account, owned: $0.owned)
    }
    let settings = state.calendar
    return CalendarPaneState(
      access: CalendarAccess(rawValue: data.access.rawValue)!, calendars: calendars,
      options: LiveCalendarOptions(
        alertLead: settings.alertLead, alertCondition: settings.alertCondition.rawValue, showPreview: settings.showPreview,
        showTimeToNext: settings.showTimeToNext, hiddenCalendarIds: settings.hiddenCalendarIds
      )
    )
  }
}
