import AppKit
import ExpoModulesCore
import Foundation
import SolaraModel
import SolaraOmnibox
import SolaraStore
import SolaraUI

public class NewTabModule: Module {
  public func definition() -> ModuleDefinition {
    Name("SolaraNewTab")

    Function("available") { () -> Bool in
      LaunchSwitches.shared.isOn(.nativeNewTab, defaultOn: true) && NativeSettingsHandle.active
    }

    AsyncFunction("setTabs") { (profileId: String, json: String) in
      let rows = NewTabRows.tabs(json)
      await MainActor.run { NewTabSources.shared.setTabs(rows, profileId: profileId) }
    }

    AsyncFunction("setHistory") { (profileId: String, rev: Int, json: String) in
      let rows = NewTabRows.history(json)
      await MainActor.run { NewTabSources.shared.setHistory(rows, profileId: profileId, rev: rev) }
    }

    AsyncFunction("patchHistory") { (profileId: String, base: Int, rev: Int, json: String) -> Bool in
      guard let patch = NewTabRows.historyPatch(json) else { return false }
      return await MainActor.run { NewTabSources.shared.patchHistory(patch, profileId: profileId, base: base, rev: rev) }
    }

    AsyncFunction("setBookmarks") { (profileId: String, json: String) in
      let rows = NewTabRows.bookmarks(json)
      await MainActor.run { NewTabSources.shared.setBookmarks(rows, profileId: profileId) }
    }

    AsyncFunction("setActions") { (windowId: String, json: String) in
      let rows = NewTabRows.actions(json)
      await MainActor.run { NewTabSources.shared.setActions(rows, windowId: windowId) }
    }

    AsyncFunction("setExtensions") { (windowId: String, json: String) in
      let rows = NewTabRows.extensions(json)
      await MainActor.run { NewTabSources.shared.setExtensions(rows, windowId: windowId) }
    }

    AsyncFunction("forgetWindow") { (windowId: String) in
      await MainActor.run { NewTabSources.shared.forget(windowId: windowId) }
    }

    View(NativeNewTabView.self) {
      Events(NativeNewTabView.events)

      Prop("windowId") { (view: NativeNewTabView, v: String) in MainActor.assumeIsolated { view.windowId = v } }
      Prop("tabId") { (view: NativeNewTabView, v: String) in MainActor.assumeIsolated { view.tabId = v } }
      Prop("profileId") { (view: NativeNewTabView, v: String) in MainActor.assumeIsolated { view.profileId = v } }
      Prop("incognito") { (view: NativeNewTabView, v: Bool?) in MainActor.assumeIsolated { view.hero.incognito = v ?? false } }
      Prop("onboarding") { (view: NativeNewTabView, v: Bool?) in MainActor.assumeIsolated { view.hero.onboarding = v ?? false } }
      Prop("playIntro") { (view: NativeNewTabView, v: Bool?) in MainActor.assumeIsolated { view.hero.playIntro = v ?? false } }
      Prop("panelOpen") { (view: NativeNewTabView, v: Bool?) in MainActor.assumeIsolated { view.hero.panelOpen = v ?? false } }
      Prop("under") { (view: NativeNewTabView, v: Double?) in MainActor.assumeIsolated { view.hero.under = v ?? 0 } }
      Prop("dark") { (view: NativeNewTabView, v: Bool?) in MainActor.assumeIsolated { view.dark = v ?? false } }
      Prop("theme") { (view: NativeNewTabView, v: [String: String]?) in MainActor.assumeIsolated { view.themeTokens = v ?? [:] } }
      Prop("offline") { (view: NativeNewTabView, v: Bool?) in MainActor.assumeIsolated { view.hero.fetcher = v == true ? nil : NewTabNetwork.fetcher } }
      Prop("driven") { (view: NativeNewTabView, v: Bool?) in MainActor.assumeIsolated { view.driven = v ?? false } }
      Prop("marks") { (view: NativeNewTabView, v: [String: String]?) in MainActor.assumeIsolated { view.marks = v ?? [:] } }

      OnViewDidUpdateProps { (view: NativeNewTabView) in MainActor.assumeIsolated { view.propsDidUpdate() } }

      AsyncFunction("focus") { (view: NativeNewTabView) in MainActor.assumeIsolated { view.hero.focusBar() } }.runOnQueue(.main)

      AsyncFunction("applyMenu") { (view: NativeNewTabView, choice: String) in
        MainActor.assumeIsolated { if let c = HeroMenuChoice(rawValue: choice) { view.hero.model?.apply(c) } }
      }.runOnQueue(.main)

      AsyncFunction("type") { (view: NativeNewTabView, text: String) in
        MainActor.assumeIsolated { view.hero.model?.driverType(text) }
      }.runOnQueue(.main)

      AsyncFunction("clear") { (view: NativeNewTabView) in MainActor.assumeIsolated { view.hero.model?.reset() } }.runOnQueue(.main)

      AsyncFunction("key") { (view: NativeNewTabView, key: String, mods: [String: Bool]?) in
        MainActor.assumeIsolated { _ = view.hero.model?.driverKey(key, mods ?? [:]) }
      }.runOnQueue(.main)

      AsyncFunction("select") { (view: NativeNewTabView, start: Int, end: Int) in
        MainActor.assumeIsolated { view.hero.model?.selectionChanged(TextSelection(start: start, end: end)) }
      }.runOnQueue(.main)

      AsyncFunction("submit") { (view: NativeNewTabView) in MainActor.assumeIsolated { view.hero.model?.submit() } }.runOnQueue(.main)

      AsyncFunction("driverState") { (view: NativeNewTabView) -> String in
        MainActor.assumeIsolated { view.driverStateJSON() }
      }.runOnQueue(.main)

      AsyncFunction("measure") { (view: NativeNewTabView) -> [String: Double] in MainActor.assumeIsolated { view.measure() } }.runOnQueue(.main)
    }
  }
}

enum NewTabRows {
  private static func objects(_ json: String) -> [[String: Any]] {
    guard let data = json.data(using: .utf8), let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
    return list
  }

  private static func string(_ o: [String: Any], _ key: String) -> String { o[key] as? String ?? "" }

  private static func optional(_ o: [String: Any], _ key: String) -> String? { o[key] as? String }

  static func tabs(_ json: String) -> [TabRow] {
    objects(json).map { TabRow(id: string($0, "id"), url: string($0, "url"), title: string($0, "title"), favicon: optional($0, "favicon")) }
  }

  static func history(_ json: String) -> [HistoryRow] {
    objects(json).map(historyRow)
  }

  private static func historyRow(_ o: [String: Any]) -> HistoryRow {
    HistoryRow(
      url: string(o, "url"), title: string(o, "title"), favicon: optional(o, "favicon"), visits: (o["visits"] as? Double) ?? 0,
      lastVisit: (o["lastVisit"] as? Double) ?? 0)
  }

  static func historyPatch(_ json: String) -> NewTabSources.HistoryPatch? {
    guard let data = json.data(using: .utf8), let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let removed = o["removed"] as? [String], let inserts = o["inserts"] as? [[Any]]
    else { return nil }
    var rows: [(index: Int, row: HistoryRow)] = []
    for entry in inserts {
      guard entry.count == 2, let index = entry[0] as? Int, let row = entry[1] as? [String: Any] else { return nil }
      rows.append((index, historyRow(row)))
    }
    return NewTabSources.HistoryPatch(removed: removed, inserts: rows)
  }

  static func bookmarks(_ json: String) -> [BookmarkRow] {
    objects(json).map { BookmarkRow(url: string($0, "url"), title: string($0, "title"), favicon: optional($0, "favicon")) }
  }

  static func actions(_ json: String) -> [CommandAction] {
    objects(json).map {
      CommandAction(id: string($0, "id"), title: string($0, "title"), keywords: $0["keywords"] as? [String], icon: optional($0, "icon"), hint: optional($0, "hint"))
    }
  }

  static func extensions(_ json: String) -> [ExtensionCandidate] {
    objects(json).map {
      ExtensionCandidate(id: string($0, "id"), title: string($0, "title"), icon: optional($0, "icon"), action: ($0["action"] as? Bool) ?? false, options: ($0["options"] as? Bool) ?? false)
    }
  }
}
