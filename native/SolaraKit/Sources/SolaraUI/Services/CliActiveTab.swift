import Foundation
import SolaraModel
import SolaraOmnibox
import SolaraStore

public func cliActiveBrowserId(_ state: BrowserState, browsers: [String: Int]) -> Int? {
  guard let windowId = state.ui.focusedWindowId, state.windows[windowId] != nil,
    let id = state.peeks[windowId]?.tabId ?? state.activeTabId(windowId),
    let tab = state.tabs[id], !tab.url.isEmpty, hasPage(tab), !cliInternalPage(tab),
    let browser = browsers[id], browser > 0
  else { return nil }
  return browser
}

private func cliInternalPage(_ tab: Tab) -> Bool {
  let url = tab.navigation?.url ?? tab.url
  guard let colon = url.range(of: "://") else { return false }
  let scheme = String(url[..<colon.lowerBound])
  guard isAppScheme(scheme) else { return false }
  let rest = url[colon.upperBound...]
  let host = rest.prefix { $0 != "/" && $0 != "?" && $0 != "#" }.lowercased()
  return ["history", "bookmarks", "downloads"].contains(host)
}

public struct CliActiveTabSync: Sendable {
  private var sent: Int?

  public init() {}

  public mutating func update(serverState: String?, chromeId: Int?) -> [String: Int]? {
    guard serverState == "on" || serverState == "starting" else {
      sent = nil
      return nil
    }
    let active = chromeId.flatMap { $0 >= 0 ? $0 : nil } ?? -1
    guard active != sent else { return nil }
    sent = active
    return ["active": active]
  }
}

public struct CliActiveTabBrowsers: Sendable {
  private var observed = ChromeTabsMemory()

  public init(snapshot: StripTransaction? = nil) {
    if let snapshot {
      observed.lastRev = snapshot.rev
      for strip in snapshot.strips where strip.closed != true { observed.mirror[strip.strip] = strip }
    }
  }

  public mutating func receive(_ transaction: StripTransaction) {
    guard transaction.rev > observed.lastRev else { return }
    observed.lastRev = transaction.rev
    for strip in transaction.strips { observed.mirror[strip.strip] = strip.closed == true ? nil : strip }
  }

  public func map(_ memory: ChromeTabsMemory) -> [String: Int] {
    let mirror = memory.lastRev > observed.lastRev ? memory.mirror : observed.mirror
    var browsers: [String: Int] = [:]
    for strip in mirror.values {
      for tab in strip.tabs {
        if let key = tab.key, !key.isEmpty { browsers[key] = tab.browser }
      }
    }
    return browsers
  }
}
