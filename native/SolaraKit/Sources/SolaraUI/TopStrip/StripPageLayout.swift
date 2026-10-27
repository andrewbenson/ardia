import CoreGraphics
import SolaraStore

public struct StripPlacedMember: Equatable, Sendable {
  public var member: StripMember
  public var width: CGFloat
  public var offset: CGFloat
  public var shown: Bool
}

public struct StripPlacedGroup: Equatable, Sendable {
  public var entry: StripGroupEntry
  public var chip: CGFloat
  public var width: CGFloat
  public var members: [StripPlacedMember]
  public var shown: Int?
  public var expanded: Bool { !entry.collapsed }
  public var membersStart: CGFloat { chip + StripMetrics.membersInset }
  public var geometry: StripDragGeometry {
    StripDragGeometry(members.map { StripDragSlot(tabIds: $0.member.tabIds, width: $0.width) }, gap: StripMetrics.gap)
  }
}

public enum StripPlacedKind: Equatable, Sendable {
  case dock(cells: [String], members: [String: [String]])
  case group(StripPlacedGroup)
  case tab(StripMember)
  case split(StripMember)
  case folder(StripMember)
  case newTab
}

public struct StripPlaced: Equatable, Sendable {
  public var kind: StripPlacedKind
  public var x: CGFloat
  public var width: CGFloat
  public var slot: Int?

  public var key: String {
    switch kind {
    case .dock: "dock"
    case .group(let g): "group:\(g.entry.id)"
    case .tab(let m), .split(let m), .folder(let m): "\(m.kind.rawValue):\(m.id)"
    case .newTab: "newTab"
    }
  }
}

public struct StripPageLayout: Equatable, Sendable {
  public var chip: CGFloat = StripMetrics.maxChip
  public var items: [StripPlaced] = []
  public var top = StripDragGeometry([], gap: StripMetrics.gap)
  public var dock = StripDragGeometry([], gap: StripMetrics.pinnedSpacing)
  public var dockCells: [String] = []
  public var dockMembers: [String: [String]] = [:]
  public var contentWidth: CGFloat = 0
  public var flare: CGFloat = StripMetrics.flare
  public var activeId = ""

  public init() {}

  public init(entries: [StripEntry], activeId: String, pageWidth: CGFloat, flare: CGFloat, chipWidth: (String) -> CGFloat, folderWidth: (String) -> CGFloat) {
    self.activeId = activeId
    self.flare = flare
    let gap = StripMetrics.gap
    var visible: [StripMember] = []
    var groups: [StripGroupWidth] = []
    for entry in entries {
      switch entry {
      case .dock(let cells, let members):
        dockCells += cells
        dockMembers.merge(members) { a, _ in a }
      case .group(let g):
        let shown = g.shown(active: activeId) != nil
        groups.append(StripGroupWidth(chip: chipWidth(g.id), expanded: !g.collapsed, shown: shown))
        visible += g.collapsed ? g.members.filter { $0.holds(activeId) } : g.members
      case .member(let m):
        visible.append(m)
      }
    }
    let dockWidth = dockCells.isEmpty ? 0 : StripMetrics.dockWidth(dockCells.count) + StripMetrics.dockGap
    let units = visible.reduce(0) { $0 + $1.units(active: activeId) }
    let fixed = visible.reduce(CGFloat(0)) { n, m in
      m.kind == .folder ? n + folderWidth(m.id) + (m.holds(activeId) ? StripMetrics.membersInset : gap) : n
    }
    chip = StripLayout.tabWidth(
      pageWidth: pageWidth, dockWidth: dockWidth, groups: groups, tabUnits: units, fixed: fixed, gap: gap, plus: StripMetrics.itemHeight,
      min: StripMetrics.minChip, max: StripMetrics.maxChip)
    let chip = self.chip
    func memberWidth(_ m: StripMember) -> CGFloat {
      m.kind == .folder ? folderWidth(m.id) + (m.holds(activeId) ? StripMetrics.membersInset + chip : 0) : chip * CGFloat(m.units(active: activeId))
    }
    dock = StripDragGeometry(dockCells.map { StripDragSlot(tabIds: dockMembers[$0] ?? [$0], width: StripMetrics.pinnedCell) }, gap: StripMetrics.pinnedSpacing)
    var slots: [StripDragSlot] = []
    var x = flare
    var placed: [StripPlaced] = []
    for entry in entries {
      switch entry {
      case .dock(let cells, let members):
        let width = StripMetrics.dockWidth(cells.count)
        placed.append(StripPlaced(kind: .dock(cells: cells, members: members), x: x, width: width, slot: nil))
        x += width + (StripMetrics.dockGap - gap) + gap
      case .group(let g):
        let widths = g.members.map(memberWidth)
        let shown = g.shown(active: activeId)
        let chipSize = chipWidth(g.id)
        let layout = StripLayout.groupLayout(chip: chipSize, widths: widths, gap: gap, expanded: !g.collapsed, shown: shown)
        let members = g.members.enumerated().map { i, m in StripPlacedMember(member: m, width: widths[i], offset: layout.offsets[i], shown: i == shown) }
        x += StripMetrics.groupMarginLeft
        placed.append(
          StripPlaced(
            kind: .group(StripPlacedGroup(entry: g, chip: chipSize, width: layout.width, members: members, shown: shown)), x: x, width: layout.width, slot: slots.count))
        slots.append(
          StripDragSlot(
            tabIds: g.members.flatMap(\.tabIds), width: layout.width, marginLeft: StripMetrics.groupMarginLeft, marginRight: StripMetrics.groupMarginRight))
        x += layout.width + StripMetrics.groupMarginRight + gap
      case .member(let m):
        let width = chip * CGFloat(m.units(active: activeId))
        let kind: StripPlacedKind = m.kind == .split ? .split(m) : m.kind == .folder ? .folder(m) : .tab(m)
        placed.append(StripPlaced(kind: kind, x: x, width: width, slot: slots.count))
        slots.append(StripDragSlot(tabIds: m.tabIds, width: width))
        x += width + gap
      }
    }
    x += 0.5
    placed.append(StripPlaced(kind: .newTab, x: x, width: StripMetrics.itemHeight, slot: nil))
    x += StripMetrics.itemHeight
    contentWidth = x + flare
    items = placed
    top = StripDragGeometry(slots, gap: gap)
  }

  public var topStart: CGFloat { flare + (dockCells.isEmpty ? 0 : StripMetrics.dockWidth(dockCells.count) + StripMetrics.dockGap) }

  public func span(of tabId: String) -> (x: CGFloat, width: CGFloat)? {
    if let cell = StripLayout.dockCell(dockCells, members: { dockMembers[$0] ?? [$0] }, tabId: tabId) {
      return (flare + dock.lefts[cell], StripMetrics.pinnedCell)
    }
    for item in items {
      switch item.kind {
      case .group(let g):
        guard let at = g.members.firstIndex(where: { $0.member.holds(tabId) }) else { continue }
        let m = g.members[at]
        return (item.x + g.membersStart + (g.expanded ? m.offset : 0), m.width)
      case .tab(let m), .split(let m), .folder(let m):
        if m.holds(tabId) { return (item.x, item.width) }
      default: continue
      }
    }
    return nil
  }
}
