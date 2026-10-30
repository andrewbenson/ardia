import Foundation
import SolaraModel
import SolaraOmnibox

public struct OmniboxIdleTabSources: Sendable, Equatable {
  private struct Row: Sendable, Equatable {
    let tab: Tab

    static func == (lhs: Self, rhs: Self) -> Bool {
      let a = lhs.tab
      let b = rhs.tab
      return OmniboxWorkspaceSources.rawStringsEqual(a.id, b.id)
        && OmniboxWorkspaceSources.rawStringsEqual(a.windowId, b.windowId)
        && OmniboxWorkspaceSources.rawStringsEqual(a.profileId, b.profileId)
        && OmniboxWorkspaceSources.rawStringsEqual(a.url, b.url)
        && OmniboxWorkspaceSources.rawStringsEqual(a.title, b.title)
        && OmniboxWorkspaceSources.rawStringsEqual(a.customTitle, b.customTitle)
        && OmniboxWorkspaceSources.rawStringsEqual(a.favicon, b.favicon)
        && OmniboxWorkspaceSources.rawStringsEqual(a.pinKey, b.pinKey)
        && a.pinned == b.pinned && a.lastActiveAt == b.lastActiveAt
    }
  }

  private let rows: [Row]
  private let peeks: [[UInt16]: [UInt16]]
  private let shared: Bool
  private let active: [[UInt16]: [[UInt16]: [UInt16]]]

  public init(tabs: [Tab], peeks: [String: String], shared: Bool, activeTabIds: [String: [String: String]] = [:]) {
    rows = tabs.map { Row(tab: $0) }
    self.peeks = Dictionary(uniqueKeysWithValues: peeks.map { (Array($0.key.utf16), Array($0.value.utf16)) })
    self.shared = shared
    active = Dictionary(uniqueKeysWithValues: activeTabIds.map { windowId, profiles in
      (Array(windowId.utf16), Dictionary(uniqueKeysWithValues: profiles.map { (Array($0.key.utf16), Array($0.value.utf16)) }))
    })
  }

  public init(_ state: BrowserState) {
    rows = state.tabs.values.map { Row(tab: $0) }
    peeks = Dictionary(uniqueKeysWithValues: state.peeks.map { (Array($0.key.utf16), Array($0.value.tabId.utf16)) })
    shared = state.settings.bool("shareTabsAcrossWindows")
    active = Dictionary(uniqueKeysWithValues: state.windows.map { windowId, window in
      (Array(windowId.utf16), Dictionary(uniqueKeysWithValues: window.activeTabIds.map { (Array($0.key.utf16), Array($0.value.utf16)) }))
    })
  }

  private init(rows: [Row], peeks: [[UInt16]: [UInt16]], shared: Bool, active: [[UInt16]: [[UInt16]: [UInt16]]]) {
    self.rows = rows
    self.peeks = peeks
    self.shared = shared
    self.active = active
  }

  public static func decode(_ json: String) -> Self? {
    guard let input = try? JSONValue.parse(json), let tabs = input["tabs"]?.array,
          let windows = input["windows"]?.array, let peeks = input["peeks"]?.object,
          let shared = input["shared"]?.bool else { return nil }
    var rows: [Row] = []
    var peekIds: [[UInt16]: [UInt16]] = [:]
    var active: [[UInt16]: [[UInt16]: [UInt16]]] = [:]
    for value in tabs {
      guard let object = value.object, let tab = try? Tab(json: object) else { return nil }
      rows.append(Row(tab: tab))
    }
    for value in windows {
      guard let object = value.object, let window = try? BrowserWindow(json: object) else { return nil }
      active[Array(window.id.utf16)] = Dictionary(uniqueKeysWithValues: window.activeTabIds.map { (Array($0.key.utf16), Array($0.value.utf16)) })
    }
    for (windowId, value) in peeks {
      guard let tabId = value.string else { return nil }
      peekIds[Array(windowId.utf16)] = Array(tabId.utf16)
    }
    return Self(rows: rows, peeks: peekIds, shared: shared, active: active)
  }

  public func activeTabId(windowId: String, profileId: String) -> String? {
    active[Array(windowId.utf16)]?[Array(profileId.utf16)].map { String(decoding: $0, as: UTF16.self) }
  }

  public func openTabs(windowId: String, profileId: String, excluding: String?) -> [Suggestion] {
    let windowKey = Array(windowId.utf16)
    let profileKey = Array(profileId.utf16)
    var here = Set<[UInt16]>()
    var used: [[UInt16]: Double] = [:]
    if shared {
      for row in rows where !row.tab.pinned {
        let tab = row.tab
        let key = familyKey(tab)
        if Array(tab.windowId.utf16) == windowKey { here.insert(key) }
        used[key] = max(used[key] ?? 0, tab.lastActiveAt)
      }
    }
    let projected: [OpenTabRow] = rows.compactMap { row in
      let tab = row.tab
      guard Array(tab.profileId.utf16) == profileKey,
            peeks[Array(tab.windowId.utf16)] != Array(tab.id.utf16) else { return nil }
      let key = familyKey(tab)
      if shared && !tab.pinned && Array(tab.windowId.utf16) != windowKey && here.contains(key) { return nil }
      let lastActiveAt = shared && !tab.pinned ? (used[key] ?? tab.lastActiveAt) : tab.lastActiveAt
      return OpenTabRow(id: tab.id, url: tab.url, title: title(tab), favicon: tab.favicon, lastActiveAt: lastActiveAt)
    }
    return recentTabSuggestions(projected, exclude: excluding)
  }

  private func familyKey(_ tab: Tab) -> [UInt16] {
    Array(tab.profileId.utf16) + [1] + Array((tab.pinKey ?? tab.id).utf16)
  }

  private func title(_ tab: Tab) -> String {
    if let title = tab.customTitle, !title.isEmpty { return title }
    if !tab.title.isEmpty { return tab.title }
    var label = tab.url.replacingOccurrences(of: "^[a-zA-Z][a-zA-Z0-9_+.-]*://", with: "", options: .regularExpression)
    if label.hasPrefix("www.") { label.removeFirst(4) }
    if label.hasSuffix("/") { label.removeLast() }
    return label.isEmpty ? "New Tab" : label
  }
}
