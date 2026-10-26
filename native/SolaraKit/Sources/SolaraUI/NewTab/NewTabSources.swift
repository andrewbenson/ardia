import Foundation
import Observation
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
    var historyRev: Int?
  }

  public struct HistoryPatch: Sendable, Equatable {
    public var removed: [String]
    public var inserts: [(index: Int, row: HistoryRow)]

    public init(removed: [String], inserts: [(index: Int, row: HistoryRow)]) {
      self.removed = removed
      self.inserts = inserts
    }

    public static func == (a: HistoryPatch, b: HistoryPatch) -> Bool {
      a.removed == b.removed && a.inserts.elementsEqual(b.inserts) { $0.index == $1.index && $0.row == $1.row }
    }
  }

  public private(set) var revision = 0
  @ObservationIgnored private var profiles: [String: Profile] = [:]
  @ObservationIgnored private var actions: [String: ActionIndex<CommandAction>] = [:]
  @ObservationIgnored private var extensions: [String: [ExtensionCandidate]] = [:]
  @ObservationIgnored private var warming: [String: Task<Void, Never>] = [:]

  public init() {}

  public func setTabs(_ tabs: [TabRow], profileId: String) {
    var p = profiles[profileId] ?? Profile()
    p.tabs = tabs
    p.hosts = nil
    profiles[profileId] = p
    revision += 1
  }

  public func setHistory(_ history: [HistoryRow], profileId: String, rev: Int? = nil) {
    var p = profiles[profileId] ?? Profile()
    p.history = history
    p.historyRev = rev
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

  @discardableResult
  public func patchHistory(_ patch: HistoryPatch, profileId: String, base: Int, rev: Int) -> Bool {
    guard let p = profiles[profileId], p.historyRev == base else { return false }
    let gone = Set(patch.removed)
    var next = gone.isEmpty ? p.history : p.history.filter { !gone.contains($0.url) }
    for (index, row) in patch.inserts {
      guard index >= 0, index <= next.count else { return false }
      next.insert(row, at: index)
    }
    setHistory(next, profileId: profileId, rev: rev)
    return true
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
