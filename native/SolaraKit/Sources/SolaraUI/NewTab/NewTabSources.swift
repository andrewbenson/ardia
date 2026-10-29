import Foundation
import Observation
import SolaraEngine
import SolaraOmnibox

@MainActor
@Observable
public final class NewTabSources {
  public static let shared = NewTabSources()
  static let warmSlice: Duration = .milliseconds(4)

  struct Profile {
    var tabs: [TabRow] = []
    var history: [HistoryRow] = []
    var bookmarks: [BookmarkRow] = []
    var index = SuggestionIndex(history: [], bookmarks: [])
    var historyHosts: [String] = []
    var hosts: [String]?
    var engineProfile: String?
  }

  public private(set) var revision = 0
  @ObservationIgnored private var profiles: [String: Profile] = [:]
  @ObservationIgnored private var actions: [String: ActionIndex<CommandAction>] = [:]
  @ObservationIgnored private var extensions: [String: [ExtensionCandidate]] = [:]
  @ObservationIgnored private var warming: [String: Task<Void, Never>] = [:]
  @ObservationIgnored private var historyObservers: [String: Task<Void, Never>] = [:]
  @ObservationIgnored private var historyCatalog: LibraryCatalog?

  public init() {}

  public func useHistoryCatalog(_ catalog: LibraryCatalog) {
    if let historyCatalog, historyCatalog === catalog { return }
    historyCatalog = catalog
    for (profileId, profile) in profiles {
      if let engineProfile = profile.engineProfile { observeHistory(profileId: profileId, engineProfile: engineProfile) }
    }
  }

  public func setEngineProfile(_ engineProfile: String, profileId: String) {
    var profile = profiles[profileId] ?? Profile()
    guard profile.engineProfile != engineProfile else { return }
    profile.engineProfile = engineProfile
    profiles[profileId] = profile
    observeHistory(profileId: profileId, engineProfile: engineProfile)
  }

  private func observeHistory(profileId: String, engineProfile: String) {
    historyObservers[profileId]?.cancel()
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
