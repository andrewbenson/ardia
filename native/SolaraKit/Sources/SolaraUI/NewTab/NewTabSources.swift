import Foundation
import Observation
import SolaraEngine
import SolaraOmnibox

@MainActor
@Observable
public final class NewTabSources {
  public static let shared = NewTabSources()
  static let warmSlice: Duration = .milliseconds(4)

  private struct IdleTabContext: Hashable {
    let windowId: [UInt16]
    let profileId: [UInt16]
    let excluding: [UInt16]?
  }

  struct Profile {
    var tabs: [TabRow] = []
    var history: [HistoryRow] = []
    var bookmarks: [BookmarkRow] = []
    var bookmarkIcons: [String: String] = [:]
    var bookmarkIconsByEngine: [String: [String: String]] = [:]
    var index = SuggestionIndex(history: [], bookmarks: [])
    var historyHosts: [String] = []
    var hosts: [String]?
    var engineProfile: String?
    var bookmarkEngineProfile: String?
  }

  public private(set) var revision = 0
  @ObservationIgnored private var workspaceProfileIds: Set<String> = []
  @ObservationIgnored private var idleTabs = OmniboxIdleTabSources(tabs: [], peeks: [:], shared: false)
  @ObservationIgnored private var idleTabRows: [IdleTabContext: [Suggestion]] = [:]
  #if SOLARA_PROBES
  @ObservationIgnored private(set) var idleProjectionCount = 0
  #endif
  @ObservationIgnored private var profiles: [String: Profile] = [:]
  @ObservationIgnored private var actions: [String: ActionIndex<CommandAction>] = [:]
  @ObservationIgnored private var extensions: [String: [ExtensionCandidate]] = [:]
  @ObservationIgnored private var warming: [String: Task<Void, Never>] = [:]
  @ObservationIgnored private var historyObservers: [String: Task<Void, Never>] = [:]
  @ObservationIgnored private var historyCatalog: LibraryCatalog?
  @ObservationIgnored private var bookmarkCatalog: LibraryCatalog?
  @ObservationIgnored private var bookmarkObservers: [String: Task<Void, Never>] = [:]

  public init() {}

  public func useHistoryCatalog(_ catalog: LibraryCatalog) {
    if let historyCatalog, historyCatalog === catalog { return }
    historyCatalog = catalog
    for (profileId, profile) in profiles {
      if let engineProfile = profile.engineProfile { observeHistory(profileId: profileId, engineProfile: engineProfile) }
    }
  }

  public func useBookmarkCatalog(_ catalog: LibraryCatalog) {
    if let bookmarkCatalog, bookmarkCatalog === catalog { return }
    bookmarkCatalog = catalog
    for (profileId, profile) in profiles {
      if let engineProfile = profile.bookmarkEngineProfile { observeBookmarks(profileId: profileId, engineProfile: engineProfile) }
    }
  }

  public func setEngineProfile(_ engineProfile: String, bookmarkEngineProfile: String? = nil, profileId: String) {
    var profile = profiles[profileId] ?? Profile()
    let bookmarkProfile = bookmarkEngineProfile ?? engineProfile
    let historyChanged = !OmniboxWorkspaceSources.rawStringsEqual(profile.engineProfile, engineProfile)
    let bookmarksChanged = !OmniboxWorkspaceSources.rawStringsEqual(profile.bookmarkEngineProfile, bookmarkProfile)
    guard historyChanged || bookmarksChanged else { return }
    profile.engineProfile = engineProfile
    profile.bookmarkEngineProfile = bookmarkProfile
    if bookmarksChanged { profile.bookmarkIcons = profile.bookmarkIconsByEngine[bookmarkProfile] ?? [:] }
    profiles[profileId] = profile
    if historyChanged { observeHistory(profileId: profileId, engineProfile: engineProfile) }
    if bookmarksChanged { observeBookmarks(profileId: profileId, engineProfile: bookmarkProfile) }
  }

  private func observeHistory(profileId: String, engineProfile: String) {
    historyObservers[profileId]?.cancel()
    setHistory([], profileId: profileId)
    guard let historyCatalog else { return }
    applyHistory(historyCatalog.history(engineProfile: engineProfile), profileId: profileId)
    historyObservers[profileId] = Task { [weak self] in
      for await snapshot in historyCatalog.observe(engineProfile: engineProfile) {
        guard !Task.isCancelled, self?.profiles[profileId]?.engineProfile == engineProfile else { return }
        self?.applyHistory(snapshot, profileId: profileId)
      }
    }
  }

  private func applyHistory(_ snapshot: HistorySnapshot, profileId: String) {
    let rows = snapshot.ready ? snapshot.entries.map { entry in
      HistoryRow(url: entry.url, title: entry.title, favicon: nil, visits: Double(entry.visits), lastVisit: entry.lastVisit)
    } : []
    if profiles[profileId]?.history != rows { setHistory(rows, profileId: profileId) }
  }

  private func observeBookmarks(profileId: String, engineProfile: String) {
    bookmarkObservers[profileId]?.cancel()
    setBookmarks([], profileId: profileId)
    guard let bookmarkCatalog else { return }
    applyBookmarks(bookmarkCatalog.bookmarks(engineProfile: engineProfile), profileId: profileId)
    bookmarkObservers[profileId] = Task { [weak self] in
      for await snapshot in bookmarkCatalog.observeBookmarks(engineProfile: engineProfile) {
        guard !Task.isCancelled, self?.profiles[profileId]?.bookmarkEngineProfile == engineProfile else { return }
        self?.applyBookmarks(snapshot, profileId: profileId)
      }
    }
  }

  private func applyBookmarks(_ snapshot: BookmarkSnapshot, profileId: String) {
    guard snapshot.ready, let roots = snapshot.roots else {
      if profiles[profileId]?.bookmarks != [] { setBookmarks([], profileId: profileId) }
      return
    }
    var seen = Set<String>()
    var urls = Set<String>()
    var rows: [BookmarkRow] = []
    func walk(_ id: String) {
      guard seen.insert(id).inserted, let node = snapshot.nodes[id] else { return }
      if node.isFolder {
        for child in node.children ?? [] { walk(child) }
      } else if let url = node.url, urls.insert(url).inserted {
        rows.append(BookmarkRow(url: url, title: node.title, favicon: profiles[profileId]?.bookmarkIcons[url]))
      }
    }
    walk(roots.bar)
    walk(roots.other)
    if profiles[profileId]?.bookmarks != rows { setBookmarks(rows, profileId: profileId) }
  }

  func bookmarks(_ profileId: String) -> [BookmarkRow] { profiles[profileId]?.bookmarks ?? [] }

  public func omniboxBenchSnapshot(profileId: String) -> [String: Any] {
    guard let profile = profiles[profileId] else { return ["sourceMode": "unpublished"] }
    return [
      "sourceMode": workspaceProfileIds.contains(profileId) ? "native-store" : "js-feed",
      "engineProfile": profile.engineProfile.map { $0 as Any } ?? NSNull(),
      "bookmarkEngineProfile": profile.bookmarkEngineProfile.map { $0 as Any } ?? NSNull(),
      "tabs": profile.tabs.count,
      "history": profile.history.count,
      "bookmarks": profile.bookmarks.count,
      "revision": revision,
    ]
  }

  public func setIdleTabs(_ projection: OmniboxIdleTabSources) {
    if replaceIdleTabs(projection) { revision += 1 }
  }

  private func replaceIdleTabs(_ projection: OmniboxIdleTabSources) -> Bool {
    guard idleTabs != projection else { return false }
    idleTabs = projection
    idleTabRows.removeAll(keepingCapacity: true)
    return true
  }

  public func activeTabId(windowId: String, profileId: String) -> String? {
    idleTabs.activeTabId(windowId: windowId, profileId: profileId)
  }

  public func openTabs(windowId: String, profileId: String, excluding: String?) -> [Suggestion] {
    _ = revision
    let context = IdleTabContext(windowId: Array(windowId.utf16), profileId: Array(profileId.utf16), excluding: excluding.map { Array($0.utf16) })
    if let cached = idleTabRows[context] { return cached }
    #if SOLARA_PROBES
    idleProjectionCount += 1
    #endif
    let rows = idleTabs.openTabs(windowId: windowId, profileId: profileId, excluding: excluding)
    idleTabRows[context] = rows
    return rows
  }

  public func applyWorkspace(_ workspace: OmniboxWorkspaceSources) {
    _ = replaceIdleTabs(workspace.idleTabs)
    let ids = Set(workspace.profiles.map(\.profileId))
    for profileId in Array(profiles.keys) where !ids.contains(profileId) { removeProfile(profileId) }
    workspaceProfileIds = ids
    for profile in workspace.profiles {
      setEngineProfile(profile.engineProfile, bookmarkEngineProfile: profile.bookmarkEngineProfile, profileId: profile.profileId)
      if !OmniboxWorkspaceSources.tabsEqual(profiles[profile.profileId]?.tabs ?? [], profile.tabs) {
        setTabs(profile.tabs, profileId: profile.profileId)
      }
    }
    revision += 1
  }

  public func resetWorkspace() {
    _ = replaceIdleTabs(OmniboxIdleTabSources(tabs: [], peeks: [:], shared: false))
    workspaceProfileIds = []
    for profileId in Array(profiles.keys) {
      let icons = profiles[profileId]?.bookmarkIconsByEngine ?? [:]
      removeProfile(profileId)
      var profile = Profile()
      profile.bookmarkIconsByEngine = icons
      profiles[profileId] = profile
    }
    revision += 1
  }

  private func removeProfile(_ profileId: String) {
    historyObservers.removeValue(forKey: profileId)?.cancel()
    bookmarkObservers.removeValue(forKey: profileId)?.cancel()
    warming.removeValue(forKey: profileId)?.cancel()
    profiles[profileId] = nil
  }

  public func setBookmarkIcons(_ icons: [String: String], engineProfile: String, profileId: String) {
    var profile = profiles[profileId] ?? Profile()
    profile.bookmarkIconsByEngine[engineProfile] = icons
    guard profile.bookmarkEngineProfile == engineProfile else {
      profiles[profileId] = profile
      return
    }
    guard profile.bookmarkIcons != icons else {
      profiles[profileId] = profile
      return
    }
    profile.bookmarkIcons = icons
    profiles[profileId] = profile
    if let bookmarkCatalog {
      applyBookmarks(bookmarkCatalog.bookmarks(engineProfile: engineProfile), profileId: profileId)
    }
  }


  public func setTabs(_ tabs: [TabRow], profileId: String) {
    var p = profiles[profileId] ?? Profile()
    p.tabs = tabs
    p.hosts = nil
    profiles[profileId] = p
    revision += 1
  }

  func setHistory(_ history: [HistoryRow], profileId: String) {
    var p = profiles[profileId] ?? Profile()
    p.history = history
    var seen = Set<String>()
    var hosts: [String] = []
    for h in history {
      let host = hostOf(h.url)
      if !host.isEmpty && seen.insert(host).inserted { hosts.append(host) }
    }
    p.historyHosts = hosts
    p.hosts = nil
    p.index = SuggestionIndex(history: history, bookmarks: p.bookmarks, reusing: p.index)
    profiles[profileId] = p
    warm(profileId)
    revision += 1
  }

  func history(_ profileId: String) -> [HistoryRow] { profiles[profileId]?.history ?? [] }

  public func setBookmarks(_ bookmarks: [BookmarkRow], profileId: String) {
    var p = profiles[profileId] ?? Profile()
    p.bookmarks = bookmarks
    p.index = SuggestionIndex(history: p.history, bookmarks: bookmarks, reusing: p.index)
    profiles[profileId] = p
    warm(profileId)
    revision += 1
  }

  public func setActions(_ list: [CommandAction], windowId: String) {
    actions[windowId] = ActionIndex(list)
    revision += 1
  }

  public func setExtensions(_ list: [ExtensionCandidate], windowId: String) {
    extensions[windowId] = list
    revision += 1
  }

  public func forget(windowId: String) {
    actions[windowId] = nil
    extensions[windowId] = nil
  }

  func index(_ profileId: String) -> SuggestionIndex {
    if let p = profiles[profileId] { return p.index }
    let made = Profile()
    profiles[profileId] = made
    return made.index
  }

  func tabs(_ profileId: String) -> [TabRow] { profiles[profileId]?.tabs ?? [] }

  func actions(_ windowId: String) -> ActionIndex<CommandAction>? { actions[windowId] }

  func extensions(_ windowId: String) -> [ExtensionCandidate] { extensions[windowId] ?? [] }

  func knownHosts(_ profileId: String) -> [String] {
    guard var p = profiles[profileId] else { return [] }
    if let hosts = p.hosts { return hosts }
    var hosts: [String] = []
    for t in p.tabs where !t.url.isEmpty { hosts.append(hostOf(t.url)) }
    hosts += p.historyHosts
    p.hosts = hosts
    profiles[profileId] = p
    return hosts
  }

  private func warm(_ profileId: String) {
    warming[profileId]?.cancel()
    warming[profileId] = Task { [weak self] in
      while !Task.isCancelled {
        guard let index = self?.profiles[profileId]?.index else { return }
        if index.prepare(deadline: ContinuousClock.now.advanced(by: NewTabSources.warmSlice)) { return }
        try? await Task.sleep(for: .milliseconds(16))
      }
    }
  }
}
