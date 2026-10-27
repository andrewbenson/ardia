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
  private var split: SplitView?
  private var activeId: String?
  private var fullscreenTab: String?
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

  public func update(state: BrowserState) {
    guard let window = state.windows[windowId] else { return }
    let active = window.activeTabIds[window.profileId]
    let next = Splits.splitOf(state, active)
    guard next != split || active != activeId else { return }
    split = next
    activeId = active
    needsLayout = true
  }

  public func setFullscreenTab(_ tabId: String?) {
    guard tabId != fullscreenTab else { return }
    fullscreenTab = tabId
    needsLayout = true
  }

  public func container(_ tabId: String) -> NSView? { panes[tabId]?.page }

  public override func layout() {
    super.layout()
    let rects = split == nil ? [:] : SplitLayout.panes(split: split, activeId: activeId, fullscreenTab: fullscreenTab, bounds: bounds).panes
    for (tabId, rect) in rects {
      let pane = panes[tabId] ?? make(tabId)
      pane.frame = rect
      pane.isHidden = fullscreenTab != nil && tabId != fullscreenTab
      pane.radius = tabId == fullscreenTab ? 0 : ShellMetrics.cardRadius
      pane.toolbarHeight = tabId == fullscreenTab ? 0 : toolbarHeight
    }
    for (tabId, pane) in panes where rects[tabId] == nil { drop(tabId, pane) }
  }

  public override func viewWillMove(toWindow newWindow: NSWindow?) {
    super.viewWillMove(toWindow: newWindow)
    guard newWindow == nil else { return }
    for (tabId, pane) in panes { drop(tabId, pane) }
  }

  private func make(_ tabId: String) -> SplitLeafView {
    let pane = SplitLeafView()
    pane.fill = cardColor
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
  var radius: CGFloat = ShellMetrics.cardRadius { didSet { layer?.cornerRadius = radius } }
  var toolbarHeight: CGFloat = ShellMetrics.toolbarHeight { didSet { if toolbarHeight != oldValue { needsLayout = true } } }
  var fill: NSColor = .windowBackgroundColor { didSet { layer?.backgroundColor = fill.cgColor } }

  override var isFlipped: Bool { true }

  override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
    layer?.masksToBounds = true
    layer?.cornerRadius = radius
    layer?.cornerCurve = .continuous
    layer?.backgroundColor = fill.cgColor
    addSubview(page)
  }

  required init?(coder: NSCoder) { fatalError() }

  override func layout() {
    super.layout()
    page.frame = CGRect(x: 0, y: toolbarHeight, width: bounds.width, height: max(0, bounds.height - toolbarHeight))
  }
}

@MainActor
final class SplitPageContainer: NSView {
  override var isFlipped: Bool { true }
}
