import AppKit
import SolaraModel
import SolaraStore

@MainActor
public final class SidebarView: NSView {
  public let windowId: String
  public let favicons = SidebarFavicons()
  public var onAction: (SidebarAction) -> Void = { _ in }
  public private(set) var pageLayout = SidebarPageLayout()

  private var context: SidebarContext?
  private let fixed = SidebarLayer()
  private let edgeLine = CALayer()
  private let clip = SidebarLayer()
  private let scroll = NSScrollView()
  private let document = SidebarDocumentView()
  private let boxes = SidebarLayer()
  private let rows = SidebarLayer()
  private let dock = SidebarLayer()
  private var views: [String: NSView] = [:]
  private var hoveredKey: String?
  private var hoveredGroup: String?
  private var tracking: NSTrackingArea?
  private var edgeShown = false
  private var clipShift: CGFloat = 0
  private var lastSize = NSSize.zero

  public override var isFlipped: Bool { true }

  public init(windowId: String) {
    self.windowId = windowId
    super.init(frame: .zero)
    wantsLayer = true
    edgeLine.actions = SurfaceLayer.noActions
    edgeLine.opacity = 0
    fixed.wantsLayer = true
    fixed.layer?.addSublayer(edgeLine)
    clip.wantsLayer = true
    clip.layer?.masksToBounds = true
    scroll.drawsBackground = false
    scroll.hasVerticalScroller = false
    scroll.hasHorizontalScroller = false
    scroll.verticalScrollElasticity = .allowed
    scroll.horizontalScrollElasticity = .none
    scroll.automaticallyAdjustsContentInsets = false
    scroll.contentView.drawsBackground = false
    scroll.contentView.postsBoundsChangedNotifications = true
    scroll.documentView = document
    document.owner = self
    document.addSubview(boxes)
    document.addSubview(rows)
    clip.addSubview(scroll)
    addSubview(clip)
    addSubview(fixed)
    addSubview(dock)
    NotificationCenter.default.addObserver(self, selector: #selector(scrolled), name: NSView.boundsDidChangeNotification, object: scroll.contentView)
    DevPointer.observe(self, #selector(devPointer(_:)))
  }

  required init?(coder: NSCoder) { fatalError() }

  public func update(state: BrowserState, host: SidebarHostState) {
    let next = SidebarContext(state: state, host: host, windowId: windowId, favicons: favicons, previous: context)
    next.send = { [weak self] action in self?.onAction(action) }
    let previous = context
    let moved = previous != nil && previous?.activeId != next.activeId
    context = next
    reconcile()
    if let previous { revealChanges(from: previous, to: next) }
    if moved { NotificationCenter.default.post(name: Self.selectionShown, object: self) }
  }

  private func revealChanges(from previous: SidebarContext, to next: SidebarContext) {
    let active = next.activeId
    let before = previous.activeId
    var target: String?
    if let active, active != before, !closedAway(before, previous.state, next.state) { target = active }
    if target == nil, let window = next.state.windows[windowId], let was = previous.state.windows[windowId], window.tabIds != was.tabIds {
      let had = Set(was.tabIds)
      target = window.tabIds.last { !had.contains($0) && next.state.tabs[$0]?.openerId != nil && $0 != active }
    }
    if let target { reveal(target, next) }
  }

  private func closedAway(_ tabId: String?, _ before: BrowserState, _ after: BrowserState) -> Bool {
    guard let tabId else { return false }
    guard let tab = after.tabs[tabId] else { return true }
    return tab.unloaded == true && before.tabs[tabId]?.unloaded != true
  }

  private func reveal(_ tabId: String, _ context: SidebarContext) {
    let shown = pageLayout.items.filter { $0.region == .scroll }
    let item =
      shown.first { $0.kind == .tab(tabId) }
      ?? shown.first { if case .split(let id) = $0.kind { context.query.holdsTab("s:\(id)", tabId) } else { false } }
      ?? shown.last { if case .groupHeader(let id) = $0.kind { context.query.holdsTab("g:\(id)", tabId) } else { false } }
    guard let item else { return }
    let viewport = scroll.frame.height
    let top = scroll.contentView.bounds.minY
    let y = item.frame.minY
    let pad = SidebarMetrics.glowRoom + SidebarMetrics.edgeInset
    var to: CGFloat
    if y - top < SidebarMetrics.glowRoom {
      to = max(0, y - pad)
    } else if item.frame.maxY - top > viewport - 8 {
      to = item.frame.maxY - viewport + 8
    } else {
      return
    }
    to = min(to, max(0, document.frame.height - viewport))
    guard abs(to - top) > 0.5 else { return }
    NSAnimationContext.runAnimationGroup { motion in
      motion.duration = 0.25
      motion.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
      scroll.contentView.animator().setBoundsOrigin(NSPoint(x: 0, y: to))
    }
    scroll.reflectScrolledClipView(scroll.contentView)
  }

  public static let selectionShown = Notification.Name("SolaraSidebarSelectionShown")

  public func updateHost(_ host: SidebarHostState) {
    guard let context else { return }
    update(state: context.state, host: host)
  }

  public func frameOf(_ key: String) -> NSRect? {
    guard let view = [key, "t:\(key)", "tile:\(key)", "gh:\(key)", "folder:\(key)"].lazy.compactMap({ self.views[$0] }).first else { return nil }
    if view.superview == nil || view.isHidden { return nil }
    return view.convert(view.bounds, to: self)
  }

  public var hoverKey: String? { hoveredKey }

  public func hoverShifts() -> (hovered: Int, shifts: [String]) {
    let rows = views.values.compactMap { $0 as? SidebarRowView }.filter { $0.window != nil && !$0.isHidden }
    func placed() -> [String: CGRect] {
      var out: [String: CGRect] = [:]
      for row in rows {
        let key = row.item?.key ?? ""
        out[key] = row.frame
        for (i, view) in row.body.subviews.enumerated() where !view.isHidden {
          out["\(key)/\(i)"] = CGRect(origin: view.frame.origin, size: .zero)
        }
      }
      return out
    }
    var shifts: [String] = []
    for row in rows {
      let before = placed()
      row.hovered = true
      layoutSubtreeIfNeeded()
      let after = placed()
      row.hovered = false
      layoutSubtreeIfNeeded()
      for (key, frame) in before {
        guard let moved = after[key], moved != frame else { continue }
        shifts.append("hovering \(row.item?.key ?? ""): \(key) \(frame) -> \(moved)")
      }
    }
    return (rows.count, shifts)
  }

  public override func layout() {
    super.layout()
    if bounds.size != lastSize {
      lastSize = bounds.size
      reconcile()
    }
  }

  private func reconcile() {
    guard let context, bounds.width > 0 else { return }
    var input = SidebarLayoutInput(windowId: windowId, profileId: context.host.profileId, width: bounds.width, height: bounds.height)
    input.addressBar = context.host.addressBar
    input.newTabAtTop = context.host.newTabAtTop
    input.balanced = context.state.settings.bool("balancedTopApps")
    let entries = context.query.entries(windowId: windowId, profileId: context.host.profileId)
    context.host.clear = context.showClear && !entries.list.isEmpty
    input.divided = context.host.tidy || context.host.clear
    input.incognitoBadge = context.host.addressBar && context.host.incognito
    let next = SidebarLayout(query: context.query, input: input).layout(entries)
    pageLayout = next
    place(next, context)
  }

  private func place(_ layout: SidebarPageLayout, _ context: SidebarContext) {
    let width = bounds.width
    let inset = SidebarMetrics.inset
    fixed.frame = NSRect(x: 0, y: 0, width: width, height: layout.fixedHeight)
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    edgeLine.frame = CGRect(x: 0, y: layout.lineY, width: width, height: SidebarMetrics.edgeLine)
    edgeLine.backgroundColor = context.palette.scrollEdge.cgColor
    CATransaction.commit()
    let scrollHeight = max(0, layout.scrollBottom - layout.scrollTop)
    clip.frame = NSRect(x: 0, y: layout.scrollTop + clipShift, width: width, height: max(0, scrollHeight - clipShift))
    scroll.frame = NSRect(x: 0, y: -clipShift, width: width, height: scrollHeight)
    let docHeight = max(layout.contentHeight, scrollHeight)
    if document.frame.size != NSSize(width: width, height: docHeight) {
      document.frame = NSRect(x: 0, y: 0, width: width, height: docHeight)
    }
    boxes.frame = NSRect(x: inset, y: 0, width: width - inset * 2, height: docHeight)
    rows.frame = boxes.frame
    dock.frame = bounds

    var seen = Set<String>()
    for item in layout.items {
      seen.insert(item.key)
      let parent: NSView
      switch (item.region, item.kind) {
      case (.fixed, _): parent = fixed
      case (.dock, _): parent = dock
      case (_, .groupBox): parent = boxes
      default: parent = rows
      }
      let view = views[item.key] ?? make(item.kind)
      views[item.key] = view
      if view.superview !== parent { parent.addSubview(view) }
      if view.frame != item.frame { view.frame = item.frame }
      if let row = view as? SidebarRowView {
        row.update(item, context)
        row.hovered = hoveredKey == item.key
      } else if let box = view as? GroupBoxView {
        box.update(item, context)
        box.show(hoveredGroup == groupId(item.kind), animated: false)
      }
    }
    for (key, view) in views where !seen.contains(key) {
      view.removeFromSuperview()
      views[key] = nil
    }
    if let hoveredKey, !seen.contains(hoveredKey) { self.hoveredKey = nil }
    syncEdge()
  }

  private func groupId(_ kind: SidebarItemKind) -> String? {
    if case .groupBox(let id) = kind { return id }
    return nil
  }

  private func make(_ kind: SidebarItemKind) -> NSView {
    switch kind {
    case .tab: TabRowView()
    case .split: SplitRowView()
    case .groupHeader: GroupHeaderView()
    case .groupBox: GroupBoxView()
    case .newTab: NewTabRowView()
    case .divider: DividerRowView()
    case .tile, .folder: TileView()
    case .incognito: IncognitoBadgeView()
    }
  }

  @objc private func scrolled() {
    syncEdge()
    syncPointer()
  }

  private func syncEdge() {
    let y = scroll.contentView.bounds.origin.y
    let shown = y > 0
    if shown != edgeShown {
      edgeShown = shown
      let fade = CABasicAnimation(keyPath: "opacity")
      fade.fromValue = edgeLine.presentation()?.opacity ?? edgeLine.opacity
      fade.toValue = shown ? 1 : 0
      fade.duration = 0.1
      fade.timingFunction = CAMediaTimingFunction(controlPoints: 0.25, 0.46, 0.45, 0.94)
      edgeLine.opacity = shown ? 1 : 0
      edgeLine.add(fade, forKey: "edge")
    }
    let shift = min(max(y, 0), 1) * SidebarMetrics.glowRoom
    if shift != clipShift {
      clipShift = shift
      let scrollHeight = max(0, pageLayout.scrollBottom - pageLayout.scrollTop)
      clip.frame = NSRect(x: 0, y: pageLayout.scrollTop + shift, width: bounds.width, height: max(0, scrollHeight - shift))
      scroll.frame = NSRect(x: 0, y: -shift, width: bounds.width, height: scrollHeight)
    }
  }

  public override func updateTrackingAreas() {
    super.updateTrackingAreas()
    if let tracking { removeTrackingArea(tracking) }
    let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect], owner: self)
    addTrackingArea(area)
    tracking = area
  }

  public override func mouseEntered(with event: NSEvent) { point(event.locationInWindow) }
  public override func mouseMoved(with event: NSEvent) { point(event.locationInWindow) }
  public override func mouseExited(with event: NSEvent) { setHover(nil, group: nil) }

  private func syncPointer() {
    guard let window else { return }
    let at = window.mouseLocationOutsideOfEventStream
    if bounds.contains(convert(at, from: nil)) { point(at) } else { setHover(nil, group: nil) }
  }

  @objc private func devPointer(_ note: Notification) {
    guard let window, let screen = (note.object as? NSValue)?.pointValue else { return }
    let at = window.convertPoint(fromScreen: screen)
    if DevPointer.inside(self, note) { point(at) } else { setHover(nil, group: nil) }
  }

  private func point(_ windowPoint: NSPoint) {
    let row = rowAt(windowPoint)
    let groups = groupsAt(windowPoint)
    setHover(row, group: groups)
    row?.pointerMoved()
  }

  private func rowAt(_ windowPoint: NSPoint) -> SidebarRowView? {
    for container in [dock, fixed, rows] {
      if container === rows, !clip.bounds.contains(clip.convert(windowPoint, from: nil)) { continue }
      for case let row as SidebarRowView in container.subviews.reversed() where !row.isHidden {
        if row.bounds.contains(row.convert(windowPoint, from: nil)) { return row }
      }
    }
    return nil
  }

  private func groupsAt(_ windowPoint: NSPoint) -> String? {
    guard clip.bounds.contains(clip.convert(windowPoint, from: nil)) else { return nil }
    var best: (id: String, depth: Int)?
    for case let box as GroupBoxView in boxes.subviews {
      guard let item = box.item, case .groupBox(let id) = item.kind, box.bounds.contains(box.convert(windowPoint, from: nil)) else { continue }
      if best == nil || item.groups.count > best!.depth { best = (id, item.groups.count) }
    }
    return best?.id
  }

  func pointerEntered(_ row: SidebarRowView) {
    setHover(row, group: row.item?.groups.last)
  }

  func pointerExited(_ row: SidebarRowView) {
    if hoveredKey == row.item?.key { setHover(nil, group: nil) }
  }

  private var sentTarget: String?

  func dismissHover() { sentTarget = nil }

  func hoverTargetMoved() { sendHoverTarget() }

  private func sendHoverTarget() {
    let row = hoveredKey.flatMap { views[$0] as? SidebarRowView }
    let target = row?.hoverTarget
    let key = target.map { "\($0.kind):\($0.id)" }
    guard key != sentTarget else { return }
    sentTarget = key
    onAction(.hover(kind: target?.kind, id: target?.id))
  }

  private func setHover(_ row: SidebarRowView?, group: String?) {
    let key = row?.item?.key
    if key != hoveredKey {
      if let old = hoveredKey, let view = views[old] as? SidebarRowView { view.hovered = false }
      hoveredKey = key
      row?.hovered = true
      sendHoverTarget()
    }
    if group != hoveredGroup {
      if let old = hoveredGroup, let box = views["gb:\(old)"] as? GroupBoxView { box.show(false, animated: true) }
      hoveredGroup = group
      if let group, let box = views["gb:\(group)"] as? GroupBoxView { box.show(true, animated: true) }
    }
  }

  fileprivate func blankMouseDown(_ event: NSEvent) {
    if event.modifierFlags.contains(.control) { return onAction(.sidebarMenu) }
    if event.clickCount == 2 { return onAction(.newTabDoubleClick) }
    window?.performDrag(with: event)
  }

  public override func mouseDown(with event: NSEvent) { blankMouseDown(event) }
  public override func rightMouseDown(with event: NSEvent) { onAction(.sidebarMenu) }
  public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

final class SidebarLayer: NSView {
  override var isFlipped: Bool { true }

  override func hitTest(_ point: NSPoint) -> NSView? {
    let hit = super.hitTest(point)
    return hit === self ? nil : hit
  }
}

final class SidebarDocumentView: NSView {
  weak var owner: SidebarView?
  override var isFlipped: Bool { true }
  override func mouseDown(with event: NSEvent) { owner?.blankMouseDown(event) }
  override func rightMouseDown(with event: NSEvent) { owner?.onAction(.sidebarMenu) }
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
