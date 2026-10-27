import AppKit
import QuartzCore
import SolaraModel
import SolaraStore

@MainActor
final class StripDocumentView: NSView {
  override var isFlipped: Bool { true }

  override func hitTest(_ point: NSPoint) -> NSView? {
    let hit = super.hitTest(point)
    return hit === self ? nil : hit
  }
}

@MainActor
final class StripClipView: NSClipView {
  override func hitTest(_ point: NSPoint) -> NSView? {
    let hit = super.hitTest(point)
    return hit === self ? nil : hit
  }
}

@MainActor
final class StripScrollView: NSScrollView {
  override func hitTest(_ point: NSPoint) -> NSView? {
    let hit = super.hitTest(point)
    return hit === self ? nil : hit
  }
}

@MainActor
public final class StripPageView: NSView {
  public let windowId: String
  public let profileId: String
  let favicons: SidebarFavicons
  var onAction: (StripAction) -> Void = { _ in }
  public private(set) var pageLayout = StripPageLayout()

  private var context: StripContext?
  private let scroll = StripScrollView()
  private let document = StripDocumentView()
  private let dock = StripDockView()
  private let newTab = StripNewTabButton()
  private var tabs: [String: StripTabChip] = [:]
  private var splits: [String: StripSplitChip] = [:]
  private var groups: [String: StripGroupView] = [:]
  private var hoveredViews: [StripHoverView] = []
  private var tracking: NSTrackingArea?
  private var revealed: String?
  var pageWidth: CGFloat = 0

  public override var isFlipped: Bool { true }

  init(windowId: String, profileId: String, favicons: SidebarFavicons) {
    self.windowId = windowId
    self.profileId = profileId
    self.favicons = favicons
    super.init(frame: .zero)
    wantsLayer = true
    let clip = StripClipView()
    clip.drawsBackground = false
    scroll.contentView = clip
    scroll.drawsBackground = false
    scroll.hasHorizontalScroller = false
    scroll.hasVerticalScroller = false
    scroll.verticalScrollElasticity = .none
    scroll.horizontalScrollElasticity = .allowed
    scroll.automaticallyAdjustsContentInsets = false
    scroll.contentView.postsBoundsChangedNotifications = true
    scroll.documentView = document
    document.addSubview(dock)
    document.addSubview(newTab)
    addSubview(scroll)
    NotificationCenter.default.addObserver(self, selector: #selector(scrolled), name: NSView.boundsDidChangeNotification, object: scroll.contentView)
    DevPointer.observe(self, #selector(devPointer(_:)))
  }

  required init?(coder: NSCoder) { fatalError() }

  public override func hitTest(_ point: NSPoint) -> NSView? {
    let hit = super.hitTest(point)
    return hit === self ? nil : hit
  }

  public var scrolledX: CGFloat { scroll.contentView.bounds.minX }

  func update(state: BrowserState, host: StripHostState, current: Bool) {
    let next = StripContext(state: state, host: host, windowId: windowId, favicons: favicons, previous: context)
    next.send = { [weak self] action in self?.onAction(action) }
    let first = context == nil
    context = next
    reconcile(next)
    if first {
      revealed = next.activeId
    } else if current, revealed != next.activeId {
      revealed = next.activeId
      DispatchQueue.main.async { [weak self] in self?.revealActive(animated: true) }
    }
  }

  private func chipWidth(_ groupId: String, _ context: StripContext) -> CGFloat {
    context.state.groups[groupId].map(StripText.groupChipWidth) ?? 0
  }

  private func reconcile(_ context: StripContext) {
    let entries = context.query.entries(windowId: windowId, profileId: profileId)
    let layout = StripPageLayout(
      entries: entries, activeId: context.activeId, pageWidth: pageWidth, flare: context.host.floating ? 0 : StripMetrics.flare,
      chipWidth: { chipWidth($0, context) },
      folderWidth: { StripText.folderChipWidth(context.query.groupLabel($0)) })
    pageLayout = layout
    var liveTabs = Set<String>()
    var liveSplits = Set<String>()
    var liveGroups = Set<String>()
    let h = StripMetrics.height
    dock.isHidden = layout.dockCells.isEmpty
    for item in layout.items {
      switch item.kind {
      case .dock(let cells, let members):
        dock.frame = NSRect(x: item.x, y: StripMetrics.itemTop, width: item.width, height: StripMetrics.itemHeight)
        dock.update(cells: cells, members: members, geometry: layout.dock, context)
      case .tab(let m):
        liveTabs.insert(m.id)
        let view = tabs[m.id] ?? make { StripTabChip() }
        tabs[m.id] = view
        view.frame = NSRect(x: StripLayout.pixel(item.x), y: 0, width: StripLayout.pixel(item.width), height: h)
        view.layer?.zPosition = context.activeId == m.id ? 1 : 0
        view.update(m.id, context)
      case .split(let m):
        liveSplits.insert(m.id)
        let view = splits[m.id] ?? make { StripSplitChip() }
        splits[m.id] = view
        view.frame = NSRect(x: StripLayout.pixel(item.x), y: 0, width: StripLayout.pixel(item.width), height: h)
        view.layer?.zPosition = m.tabIds.contains(context.activeId) ? 1 : 0
        view.update(m.tabIds, context)
      case .folder:
        break
      case .group(let g):
        liveGroups.insert(g.entry.id)
        let view = groups[g.entry.id] ?? make { StripGroupView() }
        groups[g.entry.id] = view
        view.frame = NSRect(x: StripLayout.pixel(item.x), y: 0, width: StripLayout.pixel(g.width), height: h)
        view.size = StripLayout.pixel(g.width)
        view.open = g.expanded ? 1 : 0
        view.update(g, chip: layout.chip, context)
      case .newTab:
        newTab.frame = NSRect(x: StripLayout.pixel(item.x), y: StripMetrics.itemTop, width: StripMetrics.itemHeight, height: StripMetrics.itemHeight)
        newTab.update(context)
      }
    }
    for (id, view) in tabs where !liveTabs.contains(id) {
      view.removeFromSuperview()
      tabs[id] = nil
    }
    for (id, view) in splits where !liveSplits.contains(id) {
      view.removeFromSuperview()
      splits[id] = nil
    }
    for (id, view) in groups where !liveGroups.contains(id) {
      view.removeFromSuperview()
      groups[id] = nil
    }
    document.frame = NSRect(x: 0, y: 0, width: max(layout.contentWidth, scroll.frame.width), height: h)
    syncHover()
  }

  private func make<V: NSView>(_ build: () -> V) -> V {
    let view = build()
    document.addSubview(view, positioned: .below, relativeTo: newTab)
    return view
  }

  public override func layout() {
    super.layout()
    scroll.frame = bounds
    document.frame.size.height = bounds.height
  }

  func revealActive(animated: Bool) {
    guard let context, !context.activeId.isEmpty, let span = pageLayout.span(of: context.activeId) else { return }
    let viewport = bounds.width
    guard let x = StripLayout.revealOffset(left: span.x, width: span.width, scrolled: scrolledX, viewport: viewport, pad: pageLayout.flare + StripMetrics.gap) else { return }
    let to = min(x, max(0, document.frame.width - viewport))
    if animated {
      NSAnimationContext.runAnimationGroup { motion in
        motion.duration = 0.3
        scroll.contentView.animator().setBoundsOrigin(NSPoint(x: to, y: 0))
      }
    } else {
      scroll.contentView.setBoundsOrigin(NSPoint(x: to, y: 0))
    }
    scroll.reflectScrolledClipView(scroll.contentView)
  }

  @objc private func scrolled() { syncHover() }

  public override func updateTrackingAreas() {
    super.updateTrackingAreas()
    if let tracking { removeTrackingArea(tracking) }
    let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
    addTrackingArea(area)
    tracking = area
  }

  public override func mouseMoved(with event: NSEvent) { hover(at: convert(event.locationInWindow, from: nil)) }
  public override func mouseEntered(with event: NSEvent) { hover(at: convert(event.locationInWindow, from: nil)) }
  public override func mouseExited(with event: NSEvent) { hover(at: nil) }

  @objc private func devPointer(_ note: Notification) {
    guard let window, let screen = (note.object as? NSValue)?.pointValue else { return hover(at: nil) }
    let point = convert(window.convertPoint(fromScreen: screen), from: nil)
    hover(at: bounds.contains(point) && !isHiddenOrHasHiddenAncestor ? point : nil)
  }

  func syncHover() {
    guard let window, !isHiddenOrHasHiddenAncestor else { return hover(at: nil) }
    let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
    hover(at: bounds.contains(point) ? point : nil)
  }

  private func hover(at point: NSPoint?) {
    var next: [StripHoverView] = []
    if let point, let superview, var view = hitTest(convert(point, to: superview)) {
      while true {
        if let hoverable = view as? StripHoverView { next.append(hoverable) }
        guard let up = view.superview, up !== self else { break }
        view = up
      }
    }
    for view in hoveredViews where !next.contains(where: { $0 === view }) { view.hovered = false }
    for view in next { view.hovered = true }
    hoveredViews = next
  }

  public func frameOf(_ key: String) -> NSRect? {
    let view: NSView? =
      if key.hasPrefix("t:") { tabs[String(key.dropFirst(2))] ?? groupMemberChip(String(key.dropFirst(2))) ?? dock.cell(String(key.dropFirst(2))) }
      else if key.hasPrefix("s:") { splits[String(key.dropFirst(2))] }
      else if key.hasPrefix("g:") { groups[String(key.dropFirst(2))] }
      else if key == "newTab" { newTab }
      else { nil }
    guard let view, view.superview != nil else { return nil }
    return view.convert(view.bounds, to: self)
  }

  private func groupMemberChip(_ tabId: String) -> NSView? {
    for group in groups.values {
      for member in group.memberViews {
        for chip in member.chips { if let tab = chip as? StripTabChip, tab.tabId == tabId { return tab } }
      }
    }
    return nil
  }

  public func describe() -> [[String: Any]] {
    var out: [[String: Any]] = []
    func add(_ kind: String, _ id: String, _ view: NSView) {
      guard !view.isHidden, view.superview != nil else { return }
      let f = view.convert(view.bounds, to: self)
      out.append(["kind": kind, "id": id, "x": f.minX, "y": f.minY, "width": f.width, "height": f.height, "alpha": view.alphaValue])
    }
    for id in dock.order { if let cell = dock.cell(id) { add("pinned", id, cell) } }
    for (id, view) in tabs { add("tab", id, view) }
    for (id, view) in splits { add("split", id, view) }
    for (id, view) in groups {
      add("group", id, view)
      add("groupChip", id, view.header)
      for member in view.memberViews {
        for chip in member.chips {
          if let tab = chip as? StripTabChip, let tabId = tab.tabId { add("tab", tabId, tab) }
          if let folder = chip as? StripFolderChip { add("folderChip", folder.groupId, folder) }
          if let split = chip as? StripSplitChip { add("split", split.tabIds.joined(separator: ","), split) }
        }
      }
    }
    add("newTab", "", newTab)
    return out.sorted { ($0["x"] as? CGFloat ?? 0) < ($1["x"] as? CGFloat ?? 0) }
  }

  public func hoverShifts() -> (hovered: [String], shifts: [String]) {
    var shifts: [String] = []
    var hovered: [String] = []
    let views = allHoverViews()
    for view in views {
      let before = describe()
      view.hovered = true
      layoutSubtreeIfNeeded()
      let during = describe()
      view.hovered = false
      hovered.append(String(describing: type(of: view)))
      if before.count != during.count { shifts.append("\(type(of: view)) changed the item count") }
      for (a, b) in zip(before, during) where !Self.same(a, b) { shifts.append("\(type(of: view)) moved \(a["kind"] ?? "")/\(a["id"] ?? "")") }
    }
    syncHover()
    return (hovered, shifts)
  }

  private static func same(_ a: [String: Any], _ b: [String: Any]) -> Bool {
    ["x", "y", "width", "height"].allSatisfy { (a[$0] as? CGFloat) == (b[$0] as? CGFloat) }
  }

  private func allHoverViews() -> [StripHoverView] {
    var out: [StripHoverView] = []
    func walk(_ v: NSView) {
      if let h = v as? StripHoverView, !h.isHiddenOrHasHiddenAncestor { out.append(h) }
      for s in v.subviews { walk(s) }
    }
    walk(document)
    return out
  }
}
