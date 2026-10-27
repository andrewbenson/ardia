import AppKit
import QuartzCore
import SolaraModel
import SolaraStore

@MainActor
final class StripMemberView: NSView {
  private(set) var member: StripMember?
  private var tabChip: StripTabChip?
  private var splitChip: StripSplitChip?
  private var folderChip: StripFolderChip?
  var interactive = true

  override var isFlipped: Bool { true }

  override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
  }

  required init?(coder: NSCoder) { fatalError() }

  override func hitTest(_ point: NSPoint) -> NSView? {
    guard interactive, !isHidden, alphaValue > 0 else { return nil }
    let hit = super.hitTest(point)
    return hit === self ? nil : hit
  }

  func update(_ placed: StripPlacedMember, chip: CGFloat, tuck: (() -> Void)?, _ context: StripContext) {
    let m = placed.member
    if member?.kind != m.kind {
      for v in subviews { v.removeFromSuperview() }
      tabChip = nil
      splitChip = nil
      folderChip = nil
    }
    member = m
    let h = StripMetrics.height
    switch m.kind {
    case .tab:
      let view = tabChip ?? StripTabChip()
      if view.superview == nil { addSubview(view) }
      tabChip = view
      view.tuck = tuck
      view.frame = NSRect(x: 0, y: 0, width: placed.width, height: h)
      view.update(m.id, context)
    case .split:
      let view = splitChip ?? StripSplitChip()
      if view.superview == nil { addSubview(view) }
      splitChip = view
      view.frame = NSRect(x: 0, y: 0, width: placed.width, height: h)
      view.update(m.tabIds, context)
    case .folder:
      let view = folderChip ?? StripFolderChip()
      if view.superview == nil { addSubview(view) }
      folderChip = view
      let label = context.query.groupLabel(m.id)
      let width = StripText.folderChipWidth(label)
      view.frame = NSRect(x: 0, y: StripMetrics.mid - StripMetrics.folderHeight / 2, width: width, height: StripMetrics.folderHeight)
      let shownTab = m.tabIds.contains(context.activeId) ? context.activeId : nil
      if let group = context.state.groups[m.id] { view.update(group, label: label, holding: shownTab != nil, context) }
      if let shownTab {
        let chipView = tabChip ?? StripTabChip()
        if chipView.superview == nil { addSubview(chipView) }
        tabChip = chipView
        chipView.tuck = tuck
        chipView.frame = NSRect(x: width + StripMetrics.membersInset, y: 0, width: chip, height: h)
        chipView.update(shownTab, context)
      } else {
        tabChip?.removeFromSuperview()
        tabChip = nil
      }
    }
  }

  var chips: [NSView] { [tabChip, splitChip, folderChip].compactMap { $0 } }
}

@MainActor
final class StripGroupView: NSView {
  private let box = CALayer()
  private let ring = StripOntoRing()
  private let divider = CALayer()
  private let tail = NSView()
  private let tailLine = CALayer()
  private let close = StripIconButton()
  let header = StripGroupHeader()
  private var members: [String: StripMemberView] = [:]
  private var placed: StripPlacedGroup?
  private weak var context: StripContext?
  private var headerHovered = false
  private var hasClose = false
  var open: CGFloat = 1 { didSet { if open != oldValue { arrange() } } }
  var size: CGFloat = 0 { didSet { if size != oldValue { arrange() } } }
  var shownFade: [String: CGFloat] = [:]
  var moving = false
  var memberShift: (Int, StripMemberView) -> CGFloat = { _, _ in 0 }
  var memberRaised: (StripMemberView) -> Bool = { _ in false }
  var onto = false { didSet { if onto != oldValue { arrange() } } }

  override var isFlipped: Bool { true }
  override var mouseDownCanMoveWindow: Bool { false }

  override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
    for l in [box, divider, tailLine] {
      l.actions = SurfaceLayer.noActions
    }
    box.cornerRadius = StripMetrics.tabRadius
    box.cornerCurve = .continuous
    box.borderWidth = 0.5
    layer?.addSublayer(box)
    layer?.addSublayer(ring)
    layer?.addSublayer(divider)
    tail.wantsLayer = true
    tail.layer?.addSublayer(tailLine)
    tail.addSubview(close)
    addSubview(tail)
    addSubview(header)
    close.radius = 6
    close.onPress = { [weak self] in
      guard let self, let id = self.placed?.entry.id else { return }
      self.context?.send(.closeGroup(groupId: id))
    }
    header.onHover = { [weak self] on in
      self?.headerHovered = on
      self?.paint()
    }
  }

  required init?(coder: NSCoder) { fatalError() }

  override func hitTest(_ point: NSPoint) -> NSView? {
    let hit = super.hitTest(point)
    if hit === close && placed?.expanded != true { return nil }
    return hit === self || hit === tail ? nil : hit
  }

  var groupId: String? { placed?.entry.id }

  func update(_ placed: StripPlacedGroup, chip: CGFloat, _ context: StripContext) {
    self.placed = placed
    self.context = context
    guard let group = context.state.groups[placed.entry.id] else { return }
    header.update(group, shown: placed.shown != nil, context)
    let tuckable = !placed.expanded && placed.shown != nil
      && context.query.tuckTarget(windowId: context.windowId, profileId: context.host.profileId, groupId: group.id) != nil
    let ids = Set(placed.members.map(\.member.id))
    for (id, view) in members where !ids.contains(id) {
      view.removeFromSuperview()
      members[id] = nil
    }
    for m in placed.members {
      let view = members[m.member.id] ?? StripMemberView()
      if view.superview == nil {
        addSubview(view, positioned: .below, relativeTo: tail)
        members[m.member.id] = view
      }
      let groupId = group.id
      let tuck: (() -> Void)? = tuckable && m.shown ? { [weak context] in context?.send(.tuck(groupId: groupId)) } : nil
      view.update(m, chip: chip, tuck: tuck, context)
    }
    hasClose = context.groupClose(group.id) != nil
    if let control = context.groupClose(group.id) {
      close.set(control.icon, size: 9, weight: .semibold, color: context.base.icon, hover: context.base.toolbarHover, pressed: context.base.toolbarPressed, tooltip: control.tooltip)
    }
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    divider.backgroundColor = context.palette.groupDivider.cgColor
    tailLine.backgroundColor = context.palette.groupDivider.cgColor
    CATransaction.commit()
    paint()
    arrange()
  }

  private func paint() {
    guard let placed, let context, let group = context.state.groups[placed.entry.id] else { return }
    let base = context.base
    let tint = StripPalette.tint(group.color)
    let bare = group.color == "none"
    let fill: NSColor = tint.map { $0.withAlpha(headerHovered ? 0.24 : 0.18).ns } ?? (headerHovered ? base.groupHeaderHover : bare ? .clear : base.groupFill)
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    box.backgroundColor = fill.cgColor
    box.borderColor = (bare ? NSColor.clear : base.pinnedRestingStroke).cgColor
    CATransaction.commit()
  }

  func arrange() {
    guard let placed else { return }
    let mid = StripMetrics.mid
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    box.frame = CGRect(x: 0, y: StripMetrics.itemTop, width: size, height: StripMetrics.itemHeight)
    divider.frame = CGRect(x: placed.chip + 0.75, y: mid - 7.5, width: 0.5, height: 15)
    divider.opacity = Float(min(1, max(0, open)))
    tailLine.frame = CGRect(x: 0, y: (StripMetrics.itemHeight - 15) / 2, width: 0.5, height: 15)
    CATransaction.commit()
    if let context { ring.show(onto, width: size, palette: context.base) }
    tail.frame = NSRect(x: StripLayout.pixel(size - (StripMetrics.tailExpanded - 2.25)), y: StripMetrics.itemTop, width: 0.5 + 1 + 24, height: StripMetrics.itemHeight)
    tail.alphaValue = min(1, max(0, open))
    close.frame = NSRect(x: 1.5, y: (StripMetrics.itemHeight - 24) / 2, width: 24, height: 24)
    close.isHidden = !hasClose
    header.frame = NSRect(x: 0, y: StripMetrics.itemTop, width: placed.chip, height: StripMetrics.itemHeight)
    let start = placed.membersStart
    let openFade = min(1, max(0, open / 0.5))
    for (i, m) in placed.members.enumerated() {
      guard let view = members[m.member.id] else { continue }
      let x = start + m.offset * open
      view.frame = NSRect(x: StripLayout.pixel(x) + memberShift(i, view), y: 0, width: m.width, height: StripMetrics.height)
      view.layer?.zPosition = memberRaised(view) ? 10 : m.shown ? 2 : 1
      let shown = shownFade[m.member.id] ?? (m.shown ? 1 : 0)
      view.alphaValue = min(1, shown + openFade)
      view.interactive = StripLayout.memberInteractive(shown: m.shown, expanded: placed.expanded, moving: moving)
    }
  }

  func memberView(_ id: String) -> StripMemberView? { members[id] }
  var memberViews: [StripMemberView] { Array(members.values) }
}
