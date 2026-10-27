import AppKit
import ExpoModulesCore
import SolaraModel
import SolaraOmnibox
import SolaraStore
import SolaraUI

final class NativeOmniboxView: ExpoView {
  static let events = [
    "onOpen", "onSwitch", "onAction", "onExtension", "onRemoveHistory", "onChosen", "onOpenChip", "onDictate", "onContextMenu", "onJourney",
    "onLatency", "onBarLayout", "onDriverState", "onDone", "onCancel", "onSiteControls",
  ]

  let onOpen = EventDispatcher()
  let onSwitch = EventDispatcher()
  let onAction = EventDispatcher()
  let onExtension = EventDispatcher()
  let onRemoveHistory = EventDispatcher()
  let onChosen = EventDispatcher()
  let onOpenChip = EventDispatcher()
  let onDictate = EventDispatcher()
  let onContextMenu = EventDispatcher()
  let onJourney = EventDispatcher()
  let onLatency = EventDispatcher()
  let onBarLayout = EventDispatcher()
  let onDriverState = EventDispatcher()
  let onDone = EventDispatcher()
  let onCancel = EventDispatcher()
  let onSiteControls = EventDispatcher()

  let bar = OmniboxBarView(frame: .zero)
  var windowId = ""
  var tabId = ""
  var profileId = ""
  var variant = BarVariant.panel
  var opensTab = false
  var initialText = ""
  var themeTokens: [String: String] = [:]
  var dark = false
  var driven = false

  override var isFlipped: Bool { true }

  required init(appContext: AppContext? = nil) {
    super.init(appContext: appContext)
    bar.autoresizingMask = [.width, .height]
    bar.frame = bounds
    bar.settings = { NativeSettingsHandle.model?.settings ?? SolaraModel.Settings(values: [:]) }
    bar.fetcher = NewTabNetwork.fetcher
    bar.favicons = NewTabNetwork.favicons
    bar.events = makeEvents()
    bar.onHeight = { [weak self] height in self?.onBarLayout(["height": height]) }
    addSubview(bar)
  }

  func propsDidUpdate() {
    bar.theme = NewTabTheme(dark: dark, tokens: themeTokens)
    if !windowId.isEmpty && !tabId.isEmpty {
      bar.configure(OmniboxBarIdentity(windowId: windowId, tabId: tabId, profileId: profileId, variant: variant, opensTab: opensTab, initialText: initialText))
    }
  }

  func setOpenTabs(_ json: String) {
    guard let data = json.data(using: .utf8), let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return }
    bar.openTabs = rows.map {
      .page(url: $0["url"] as? String ?? "", title: $0["title"] as? String ?? "", favicon: $0["favicon"] as? String, tabId: $0["tabId"] as? String)
    }
  }

  private func makeEvents() -> HeroBarEvents {
    var e = HeroBarEvents()
    e.open = { [weak self] url, disposition in self?.onOpen(["url": url, "disposition": disposition.rawValue]) }
    e.switchTo = { [weak self] tab, url, disposition in self?.onSwitch(["tabId": tab, "url": url, "disposition": disposition.rawValue]) }
    e.runAction = { [weak self] id in self?.onAction(["id": id]) }
    e.runExtension = { [weak self] s in self?.onExtension(["suggestion": NewTabJSON.suggestion(s)]) }
    e.removeHistory = { [weak self] url in self?.onRemoveHistory(["url": url]) }
    e.chosen = { [weak self] s in self?.onChosen(["suggestion": s.map(NewTabJSON.suggestion) ?? NSNull()]) }
    e.openChip = { [weak self] in self?.onOpenChip([:]) }
    e.dictate = { [weak self] in self?.onDictate([:]) }
    e.contextMenu = { [weak self] hasSelection, hasValue in self?.onContextMenu(["hasSelection": hasSelection, "hasValue": hasValue]) }
    e.journey = { [weak self] mark in self?.onJourney(["mark": mark.rawValue]) }
    e.latency = { [weak self] ms in self?.onLatency(["ms": ms]) }
    e.keyShown = { [weak self] in
      guard let self else { return }
      FieldTimingMarks.atPresent("bar:\(self.windowId)", "keyShown")
    }
    e.done = { [weak self] reason in self?.onDone(["reason": reason?.rawValue ?? NSNull()]) }
    e.cancel = { [weak self] in self?.onCancel([:]) }
    e.siteControls = { [weak self] in self?.onSiteControls([:]) }
    e.changed = { [weak self] in
      guard let self, self.driven else { return }
      self.onDriverState(["json": self.driverStateJSON()])
    }
    return e
  }

  func driverStateJSON() -> String {
    guard let m = bar.model else { return "{}" }
    func sel(_ s: TextSelection) -> [String: Int] { ["start": s.start, "end": s.end] }
    let state: [String: Any] = [
      "typed": m.typed, "value": m.value, "selection": sel(m.selection), "completion": m.shown, "suggested": m.result.completion,
      "preventInline": m.suppressCompletion, "selected": m.selectedIndex, "scope": m.scope.map(NewTabJSON.scope) ?? NSNull(),
      "scopeFrom": m.scopeFrom, "tabScope": m.tabScope.map(NewTabJSON.scope) ?? NSNull(), "items": m.items.map(NewTabJSON.suggestion),
    ]
    let data = (try? JSONSerialization.data(withJSONObject: state)) ?? Data("{}".utf8)
    return String(decoding: data, as: UTF8.self)
  }

  func measure() -> [String: Double] {
    guard let window else { return [:] }
    let frame = convert(bounds, to: nil)
    let height = window.contentView?.bounds.height ?? 0
    return ["x": frame.minX, "y": height - frame.maxY, "width": frame.width, "height": frame.height]
  }
}

enum FieldTimingMarks {
  static func atPresent(_ key: String, _ kind: String) {
    NotificationCenter.default.post(name: Notification.Name("ACFieldMarkAtPresent"), object: [key, kind] as NSArray)
  }
}
