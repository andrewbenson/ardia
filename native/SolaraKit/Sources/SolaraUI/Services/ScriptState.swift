import Foundation
import SolaraModel
import SolaraOmnibox
import SolaraStore

public enum ScriptState {
  public static func tabLabel(_ tab: Tab) -> String {
    if let custom = tab.customTitle, !custom.isEmpty { return custom }
    if tab.url.isEmpty { return "New Tab" }
    if let app = appUrlOrigin(tab.url) { return app }
    guard let url = WhatwgURL(tab.url) else { return tab.title.isEmpty ? tab.url : tab.title }
    if url.protocol == "file:" {
      if !tab.title.isEmpty { return tab.title }
      let last = url.pathname.split(separator: "/", omittingEmptySubsequences: false).last.map(String.init) ?? ""
      return last.removingPercentEncoding ?? tab.url
    }
    var host = displayHost(url.hostname)
    if host.hasPrefix("www.") { host.removeFirst(4) }
    if !host.isEmpty { return host }
    return tab.title.isEmpty ? tab.url : tab.title
  }

  public static func profileName(_ state: BrowserState, _ profileId: String) -> String {
    if Ids.isIncognitoProfile(profileId) { return "Incognito" }
    return (state.profiles[profileId] ?? state.profiles[state.settings.defaultProfileId])?.name ?? "Incognito"
  }

  public static func windowTitle(_ state: BrowserState, _ windowId: String) -> String {
    guard let window = state.windows[windowId] else { return "" }
    let tab = state.activeTabId(windowId).flatMap { state.tabs[$0] }
    let others = state.viewTabIds(windowId).count - 1
    let label = tab.map(tabLabel) ?? "New Tab"
    let more = others > 0 ? " & \(others) Tab\(others == 1 ? "" : "s")" : ""
    return "\(profileName(state, window.profileId)) — \(label)\(more)"
  }

  public static func build(_ state: BrowserState, loading: Set<String>) -> [String: Any] {
    let windows: [[String: Any]] = state.windowOrder.compactMap { id in
      guard let window = state.windows[id] else { return nil }
      let tabs: [[String: Any]] = state.viewTabIds(id).compactMap { tabId in
        guard let tab = state.tabs[tabId] else { return nil }
        return [
          "id": tabId, "title": tab.customTitle.flatMap { $0.isEmpty ? nil : $0 } ?? tab.title, "url": tab.url,
          "loading": loading.contains(tabId), "pinned": tab.pinned,
        ]
      }
      return [
        "id": id, "title": windowTitle(state, id), "profileId": window.profileId, "incognito": window.incognito,
        "activeTabId": state.activeTabId(id) as Any, "tabs": tabs,
      ]
    }
    let profiles: [[String: Any]] = state.profileOrder.compactMap { id in
      state.profiles[id].map { ["id": id, "name": $0.name] }
    }
    return ["windows": windows, "profiles": profiles]
  }
}
