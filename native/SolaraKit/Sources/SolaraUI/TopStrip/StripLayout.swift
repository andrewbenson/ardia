import CoreGraphics
import Foundation

public enum StripMetrics {
  public static let height: CGFloat = 42
  public static let cardInset: CGFloat = 6
  public static let mid: CGFloat = 21
  public static let itemHeight: CGFloat = 32
  public static let itemTop: CGFloat = mid - itemHeight / 2
  public static let tabTop: CGFloat = 3
  public static let tabRadius: CGFloat = 10
  public static let flare: CGFloat = 15
  public static let rimHeight: CGFloat = 27.5
  public static let pinnedCell: CGFloat = 34
  public static let pinnedSpacing: CGFloat = 2
  public static let cellStep: CGFloat = pinnedCell + pinnedSpacing
  public static let dockGap: CGFloat = 4.5
  public static let minChip: CGFloat = 96
  public static let maxChip: CGFloat = 173
  public static let gap: CGFloat = 4
  public static let folderHeight: CGFloat = 24
  public static let folderRadius: CGFloat = 7
  public static let liftSlop: CGFloat = 12
  public static let liftDuration: Double = 0.15
  public static let lightsGap: CGFloat = 8
  public static let ontoEdge: CGFloat = maxChip / 4
  public static let groupMarginLeft: CGFloat = 3.5
  public static let groupMarginRight: CGFloat = 4
  public static let membersInset: CGFloat = 6.5
  public static let tailCollapsed: CGFloat = 4.5
  public static let tailExpanded: CGFloat = 30.25
  public static let tuckFade: Double = 0.12
  public static let pinnedFaceInset: CGFloat = 2
  public static let pinnedFaceRadius: CGFloat = 8
  public static let closeSlot: CGFloat = 20

  public static func dockWidth(_ cells: Int) -> CGFloat { CGFloat(cells) * cellStep - pinnedSpacing }
}

public struct StripSpring: Sendable, Equatable {
  public var stiffness: Double
  public var damping: Double
  public var mass: Double = 1
  public var restDisplacement: Double = 0.001
  public var restSpeed: Double = 0.001

  public static func response(_ response: Double, dampingRatio: Double) -> StripSpring {
    StripSpring(stiffness: pow(2 * Double.pi / response, 2), damping: 4 * Double.pi * dampingRatio / response)
  }

  public static let group = StripSpring.response(0.3, dampingRatio: 0.82)
  public static let slide = StripSpring(stiffness: 8100, damping: 180, restDisplacement: 0.25, restSpeed: 2)
}

public struct StripGroupLayout: Equatable, Sendable {
  public var offsets: [CGFloat]
  public var width: CGFloat
}

public struct StripDragSlot: Equatable, Sendable {
  public var tabIds: [String]
  public var width: CGFloat
  public var marginLeft: CGFloat = 0
  public var marginRight: CGFloat = 0

  public init(tabIds: [String], width: CGFloat, marginLeft: CGFloat = 0, marginRight: CGFloat = 0) {
    self.tabIds = tabIds
    self.width = width
    self.marginLeft = marginLeft
    self.marginRight = marginRight
  }
}

public struct StripDragGeometry: Equatable, Sendable {
  public var slots: [StripDragSlot]
  public var lefts: [CGFloat]

  public init(_ slots: [StripDragSlot], gap: CGFloat) {
    var lefts: [CGFloat] = []
    var x: CGFloat = 0
    for slot in slots {
      x += slot.marginLeft
      lefts.append(x)
      x += slot.width + slot.marginRight + gap
    }
    self.slots = slots
    self.lefts = lefts
  }
}

public struct StripAim: Equatable, Sendable {
  public var to: Int
  public var onto: Int?
}

public struct StripGroupWidth: Sendable {
  public var chip: CGFloat
  public var expanded: Bool
  public var shown: Bool

  public init(chip: CGFloat, expanded: Bool, shown: Bool) {
    self.chip = chip
    self.expanded = expanded
    self.shown = shown
  }
}

public enum StripLayout {
  public static func groupLayout(chip: CGFloat, widths: [CGFloat], gap: CGFloat, expanded: Bool, shown: Int?) -> StripGroupLayout {
    var offsets: [CGFloat] = []
    var x: CGFloat = 0
    for w in widths {
      offsets.append(x)
      x += w + gap
    }
    let members = widths.isEmpty ? 0 : x - gap
    if expanded && !widths.isEmpty { return StripGroupLayout(offsets: offsets, width: chip + StripMetrics.membersInset + members + StripMetrics.tailExpanded) }
    if let shown, shown < widths.count { return StripGroupLayout(offsets: offsets, width: chip + StripMetrics.membersInset + widths[shown] + StripMetrics.tailCollapsed) }
    return StripGroupLayout(offsets: offsets, width: chip)
  }

  public static func tabWidth(
    pageWidth: CGFloat, dockWidth: CGFloat, groups: [StripGroupWidth], tabUnits: Int, fixed: CGFloat, gap: CGFloat, plus: CGFloat, min: CGFloat, max: CGFloat
  ) -> CGFloat {
    var room = pageWidth - dockWidth - plus - gap - fixed
    for g in groups {
      let parts = g.expanded ? StripMetrics.membersInset + StripMetrics.tailExpanded : g.shown ? StripMetrics.membersInset + StripMetrics.tailCollapsed : 0
      room -= StripMetrics.groupMarginLeft + StripMetrics.groupMarginRight + g.chip + parts + gap
    }
    let width = tabUnits > 0 ? room / CGFloat(tabUnits) - gap : max
    return (Swift.max(min, Swift.min(max, width)) * 2).rounded(.toNearestOrAwayFromZero) / 2
  }

  public static func dragRange(_ g: StripDragGeometry, from: Int) -> ClosedRange<CGFloat> {
    let last = g.slots.count - 1
    let lower = g.lefts[0] - g.lefts[from]
    let upper = g.lefts[last] + g.slots[last].width - (g.lefts[from] + g.slots[from].width)
    return lower...Swift.max(lower, upper)
  }

  public static func dropIndex(_ g: StripDragGeometry, from: Int, dx: CGFloat) -> Int {
    let left = g.lefts[from] + dx
    let right = left + g.slots[from].width
    var index = 0
    for (i, slot) in g.slots.enumerated() {
      let centre = g.lefts[i] + slot.width / 2
      if i < from ? centre < left : i > from && centre < right { index += 1 }
    }
    return index
  }

  public static func aimDrop(_ g: StripDragGeometry, from: Int, pointer: CGFloat, target: (Int) -> Bool, edge: CGFloat) -> StripAim {
    var to = 0
    var onto: Int?
    for (i, slot) in g.slots.enumerated() where i != from {
      let left = g.lefts[i]
      let right = left + slot.width
      let takes = target(i)
      let zone = takes ? Swift.min(slot.width / 4, edge) : slot.width / 2
      if takes && pointer > left + zone && pointer < right - zone { onto = i }
      if i < from ? pointer > left + zone : pointer > right - zone { to += 1 }
    }
    return StripAim(to: to, onto: onto)
  }

  public static func leaveIndex(_ g: StripDragGeometry, slot: Int, chip: CGFloat, expanded: Bool, left: CGFloat, width: CGFloat) -> Int? {
    let start = g.lefts[slot]
    let end = start + g.slots[slot].width
    let right = left + width
    func centre(_ i: Int) -> CGFloat { g.lefts[i] + g.slots[i].width / 2 }
    if left < start + chip / 2 {
      var at = slot
      while at > 0 && centre(at - 1) > left { at -= 1 }
      return at
    }
    if right > (expanded ? end - StripMetrics.tailExpanded / 2 : end + StripMetrics.membersInset) {
      var at = slot + 1
      while at < g.slots.count && centre(at) < right { at += 1 }
      return at
    }
    return nil
  }

  public static func reorderOffsets(_ g: StripDragGeometry, from: Int, to: Int) -> [CGFloat] {
    let row = g.slots
    let gap = row.count > 1 ? g.lefts[1] - g.lefts[0] - row[0].width - row[0].marginRight - row[1].marginLeft : 0
    var order = Array(row.indices).filter { $0 != from }
    order.insert(from, at: Swift.min(Swift.max(0, to), order.count))
    let moved = StripDragGeometry(order.map { row[$0] }, gap: gap)
    var out = [CGFloat](repeating: 0, count: row.count)
    for (k, i) in order.enumerated() { out[i] = moved.lefts[k] - g.lefts[i] }
    return out
  }

  public static func dockCell(_ cells: [String], members: (String) -> [String], tabId: String) -> Int? {
    if let own = cells.firstIndex(of: tabId) { return own }
    return cells.firstIndex { members($0).contains(tabId) }
  }

  public static func revealOffset(left: CGFloat, width: CGFloat, scrolled: CGFloat, viewport: CGFloat, pad: CGFloat) -> CGFloat? {
    let toStart = left - pad
    let toEnd = left + width + pad - viewport
    let target = toStart < scrolled ? toStart : toEnd > scrolled ? Swift.min(toStart, toEnd) : scrolled
    let clamped = Swift.max(0, target)
    return abs(clamped - scrolled) < 0.5 ? nil : clamped
  }

  public static func memberInteractive(shown: Bool, expanded: Bool, moving: Bool) -> Bool {
    shown || (expanded && !moving)
  }

  public static func halfPointCeil(_ v: CGFloat) -> CGFloat { (v * 2).rounded(.up) / 2 }

  public static func pixel(_ v: CGFloat) -> CGFloat { (v * 2).rounded() / 2 }
}
