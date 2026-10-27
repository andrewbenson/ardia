import AppKit
import SolaraModel
import SolaraStore

public enum SplitLayout {
  public static func panes(split: SplitView?, activeId: String?, fullscreenTab: String?, bounds: CGRect) -> (panes: [String: CGRect], dividers: [SplitDivider]) {
    guard bounds.width > 0, bounds.height > 0 else { return ([:], []) }
    guard let split else {
      guard let id = fullscreenTab ?? activeId else { return ([:], []) }
      return ([id: bounds], [])
    }
    let geometry = ShellGeometry.split(split, width: bounds.width, height: bounds.height)
    guard let fullscreenTab else { return (geometry.panes, geometry.dividers) }
    var panes = geometry.panes
    if split.tabIds.contains(fullscreenTab) { panes[fullscreenTab] = bounds } else { panes = [fullscreenTab: bounds] }
    return (panes, [])
  }
}

@MainActor
public final class SplitPanesView: NSView {
  public let windowId: String
  public var toolbarHeight: CGFloat = ShellMetrics.toolbarHeight { didSet { if toolbarHeight != oldValue { needsLayout = true } } }
  public var cardColor: NSColor = .windowBackgroundColor { didSet { if cardColor != oldValue { panes.values.forEach { $0.fill = cardColor } } } }
  public var small = false { didSet { if small != oldValue { refreshEmpty() } } }
  public var theme = SplitChromeTheme.fallback { didSet { if theme != oldValue { panes.values.forEach { $0.empty?.theme = theme } } } }
  public var favicons: SidebarFavicons?
  public var onToolbarClick: (String, ToolbarClick) -> Void = { _, _ in }
  public var onToolbarAnchors: (String, [String: CGRect]) -> Void = { _, _ in }
  public var onNavigate: (String, String) -> Void = { _, _ in }
  public var onReplace: (String, String) -> Void = { _, _ in }
  private var split: SplitView?
  private var activeId: String?
  private var fullscreenTab: String?
  private var state: BrowserState?
  private var toolbars: [String: String] = [:]
  private var panes: [String: SplitLeafView] = [:]

  public override var isFlipped: Bool { true }

  public init(windowId: String) {
    self.windowId = windowId
    super.init(frame: .zero)
  }

  required init?(coder: NSCoder) { fatalError() }

  public override func hitTest(_ point: NSPoint) -> NSView? {
    let hit = super.hitTest(point)
    return hit === self ? nil : hit
  }

  public func update(state next: BrowserState) {
    guard let window = next.windows[windowId] else { return }
    state = next
    let active = window.activeTabIds[window.profileId]
    let nextSplit = Splits.splitOf(next, active)
    if nextSplit != split || active != activeId {
      split = nextSplit
      activeId = active
      needsLayout = true
    }
    refreshEmpty()
  }

  public func setFullscreenTab(_ tabId: String?) {
    guard tabId != fullscreenTab else { return }
    fullscreenTab = tabId
    needsLayout = true
  }

  public func setToolbars(_ next: [String: String]) {
    toolbars = next
    for (tabId, pane) in panes { pane.setToolbar(next[tabId]) }
  }

  public func container(_ tabId: String) -> NSView? { panes[tabId]?.page }

  public func toolbar(_ tabId: String) -> ToolbarView? { panes[tabId]?.toolbar }

  public func empty(_ tabId: String) -> SplitEmptyStateView? { panes[tabId]?.empty }

  public func sample() -> [String: Any] {
    func rect(_ r: CGRect) -> [Double] { [r.minX, r.minY, r.width, r.height].map(Double.init) }
    let height = window?.contentView?.bounds.height ?? 0
    return panes.mapValues { pane -> [String: Any] in
      let page = pane.page.convert(pane.page.bounds, to: nil)
      return [
        "frame": rect(pane.frame), "page": rect(pane.page.frame), "window": rect(CGRect(x: page.minX, y: height - page.maxY, width: page.width, height: page.height)),
        "toolbar": !pane.toolbar.isHidden, "empty": pane.empty != nil, "hidden": pane.isHidden, "radius": Double(pane.radius),
      ]
    }
  }

  public override func layout() {
    super.layout()
    let rects = split == nil ? [:] : SplitLayout.panes(split: split, activeId: activeId, fullscreenTab: fullscreenTab, bounds: bounds).panes
    var made = false
    for (tabId, rect) in rects {
      let pane = panes[tabId] ?? { made = true; return make(tabId) }()
      pane.frame = rect
      pane.isHidden = fullscreenTab != nil && tabId != fullscreenTab
      pane.fullscreen = tabId == fullscreenTab
      pane.toolbarHeight = tabId == fullscreenTab ? 0 : toolbarHeight
    }
    for (tabId, pane) in panes where rects[tabId] == nil { drop(tabId, pane) }
    if made { refreshEmpty() }
  }

  public override func viewWillMove(toWindow newWindow: NSWindow?) {
    super.viewWillMove(toWindow: newWindow)
    guard newWindow == nil else { return }
    for (tabId, pane) in panes { drop(tabId, pane) }
  }

  private func refreshEmpty() {
    guard let state else { return }
    for (tabId, pane) in panes {
      let tab = state.tabs[tabId]
      guard let tab, tab.url.isEmpty, !small else {
        pane.setEmpty(nil)
        continue
      }
      let view = pane.empty ?? {
        let made = SplitEmptyStateView(focused: tabId == activeId)
        made.favicons = favicons
        made.theme = theme
        made.onNavigate = { [weak self] text in self?.onNavigate(tabId, text) }
        made.onReplace = { [weak self] other in self?.onReplace(tabId, other) }
        return made
      }()
      pane.setEmpty(view)
      view.update(SplitEmptyState.suggestions(state, tabId: tabId))
    }
  }

  private func make(_ tabId: String) -> SplitLeafView {
    let pane = SplitLeafView()
    pane.fill = cardColor
    pane.toolbar.onClick = { [weak self] click in self?.onToolbarClick(tabId, click) }
    pane.toolbar.onAnchors = { [weak self] anchors in self?.onToolbarAnchors(tabId, anchors) }
    pane.setToolbar(toolbars[tabId])
    panes[tabId] = pane
    addSubview(pane)
    TabSlots.shared.set(.pane(windowId, tabId), container: pane.page)
    return pane
  }

  private func drop(_ tabId: String, _ pane: SplitLeafView) {
    TabSlots.shared.remove(.pane(windowId, tabId), container: pane.page)
    panes[tabId] = nil
    pane.removeFromSuperview()
  }
}

@MainActor
final class SplitLeafView: NSView {
  let page = SplitPageContainer()
  let toolbar = ToolbarView(frame: .zero)
  private(set) var empty: SplitEmptyStateView?
  private var toolbarJson: String?
  var fullscreen = false {
    didSet {
      guard fullscreen != oldValue else { return }
      layer?.cornerRadius = radius
      layer?.backgroundColor = fullscreen ? nil : fill.cgColor
    }
  }
  var radius: CGFloat { fullscreen ? 0 : ShellMetrics.cardRadius }
  var toolbarHeight: CGFloat = ShellMetrics.toolbarHeight { didSet { if toolbarHeight != oldValue { needsLayout = true } } }
  var fill: NSColor = .windowBackgroundColor { didSet { if !fullscreen { layer?.backgroundColor = fill.cgColor } } }

  override var isFlipped: Bool { true }

  override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
    layer?.masksToBounds = true
    layer?.cornerRadius = radius
    layer?.cornerCurve = .continuous
    layer?.backgroundColor = fill.cgColor
    addSubview(page)
    toolbar.isHidden = true
    addSubview(toolbar)
  }

  required init?(coder: NSCoder) { fatalError() }

  func setToolbar(_ json: String?) {
    guard json != toolbarJson else { return }
    toolbarJson = json
    guard let json, let state = ToolbarState.decode(json) else {
      toolbar.isHidden = true
      return
    }
    toolbar.update(state)
    toolbar.isHidden = toolbarHeight == 0
  }

  func setEmpty(_ view: SplitEmptyStateView?) {
    guard view !== empty else { return }
    empty?.removeFromSuperview()
    empty = view
    if let view { addSubview(view, positioned: .above, relativeTo: page) }
    needsLayout = true
  }

  override func layout() {
    super.layout()
    toolbar.frame = CGRect(x: 0, y: 0, width: bounds.width, height: toolbarHeight)
    toolbar.isHidden = toolbarHeight == 0 || toolbarJson == nil
    page.frame = CGRect(x: 0, y: toolbarHeight, width: bounds.width, height: max(0, bounds.height - toolbarHeight))
    empty?.frame = page.frame
  }
}

@MainActor
final class SplitPageContainer: NSView {
  override var isFlipped: Bool { true }
}
