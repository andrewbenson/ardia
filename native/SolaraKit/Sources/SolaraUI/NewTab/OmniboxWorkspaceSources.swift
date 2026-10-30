import SolaraModel
import SolaraOmnibox
import SolaraStore

public struct OmniboxWorkspaceSources: Sendable, Equatable {
  public struct Profile: Sendable, Equatable {
    public let profileId: String
    public let engineProfile: String
    public let bookmarkEngineProfile: String
    public let tabs: [TabRow]

    public static func == (lhs: Self, rhs: Self) -> Bool {
      OmniboxWorkspaceSources.rawStringsEqual(lhs.profileId, rhs.profileId)
        && OmniboxWorkspaceSources.rawStringsEqual(lhs.engineProfile, rhs.engineProfile)
        && OmniboxWorkspaceSources.rawStringsEqual(lhs.bookmarkEngineProfile, rhs.bookmarkEngineProfile)
        && OmniboxWorkspaceSources.tabsEqual(lhs.tabs, rhs.tabs)
    }
  }

  public let profiles: [Profile]
  public let idleTabs: OmniboxIdleTabSources

  static func rawStringsEqual(_ lhs: String?, _ rhs: String?) -> Bool {
    switch (lhs, rhs) {
    case let (lhs?, rhs?): lhs.utf16.elementsEqual(rhs.utf16)
    case (nil, nil): true
    default: false
    }
  }

  static func tabsEqual(_ lhs: [TabRow], _ rhs: [TabRow]) -> Bool {
    lhs.elementsEqual(rhs) { lhs, rhs in
      rawStringsEqual(lhs.id, rhs.id) && rawStringsEqual(lhs.url, rhs.url)
        && rawStringsEqual(lhs.title, rhs.title) && rawStringsEqual(lhs.favicon, rhs.favicon)
    }
  }

  public init(_ state: BrowserState) {
    idleTabs = OmniboxIdleTabSources(state)
    let windows = state.windows.values
    let tabs = state.tabs.values
    var ids: [String] = []
    var seen = Set<String>()
    for id in state.profiles.keys where !Ids.isIncognitoProfile(id) {
      if seen.insert(id).inserted { ids.append(id) }
    }
    for id in windows.map(\.profileId) + tabs.map(\.profileId) {
      if seen.insert(id).inserted { ids.append(id) }
    }
    var rows: [String: [TabRow]] = [:]
    for tab in tabs {
      rows[tab.profileId, default: []].append(TabRow(id: tab.id, url: tab.url, title: tab.title, favicon: tab.favicon))
    }
    profiles = ids.map { id in
      let window = windows.first { $0.profileId == id }
        ?? BrowserWindow(id: "", profileId: id, incognito: Ids.isIncognitoProfile(id), frame: nil, createdAt: 0)
      return Profile(profileId: id, engineProfile: state.engineProfile(id),
        bookmarkEngineProfile: state.engineProfile(state.bookmarkProfileId(window)), tabs: rows[id] ?? [])
    }
  }
}
