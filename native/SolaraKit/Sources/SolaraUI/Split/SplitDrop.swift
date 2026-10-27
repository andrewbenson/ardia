import CoreGraphics

public enum SplitSide: String, Sendable, Equatable {
  case left
  case right
}

public enum SplitZoneStage: String, Sendable, Equatable {
  case rest
  case grown
  case active

  var scale: (width: CGFloat, height: CGFloat, inset: CGFloat) {
    switch self {
    case .rest: (0.1324, 0.383, 0.025)
    case .grown: (0.215, 0.611, 0.02)
    case .active: (0.241, 0.69, 0.02)
    }
  }
}

public struct SplitDropTarget: Sendable, Equatable {
  public var tabId: String
  public var side: SplitSide

  public init(tabId: String, side: SplitSide) {
    self.tabId = tabId
    self.side = side
  }
}

public enum SplitDrop {
  public static let preview = CGSize(width: 209, height: 110)
  static let lean: CGFloat = 0.43

  public static func zoneRect(_ pane: CGRect, _ side: SplitSide, _ stage: SplitZoneStage, pointerX: CGFloat = 0) -> CGRect {
    let s = stage.scale
    let width = pane.width * s.width
    let height = pane.height * s.height
    let inset = pane.width * s.inset
    let y = pane.minY + (pane.height - height) / 2
    guard stage == .active else {
      return CGRect(x: side == .left ? pane.minX + inset : pane.maxX - inset - width, y: y, width: width, height: height)
    }
    let home = zoneRect(pane, side, .grown)
    let centre = home.midX
    let leaning = centre + (pointerX - centre) * lean
    let x = max(pane.minX + inset, min(pane.maxX - inset - width, leaning - width / 2))
    return CGRect(x: x, y: y, width: width, height: height)
  }

  public static func zoneHit(_ panes: [(tabId: String, rect: CGRect)], _ px: CGFloat, _ py: CGFloat, current: SplitDropTarget?) -> SplitDropTarget? {
    let card = CGRect(x: px - preview.width / 2, y: py - preview.height / 2, width: preview.width, height: preview.height)
    var best: (target: SplitDropTarget, distance: CGFloat)?
    for (tabId, pane) in panes {
      for side in [SplitSide.left, .right] {
        let keep = current?.tabId == tabId && current?.side == side
        let r = zoneRect(pane, side, keep ? .active : .grown, pointerX: px)
        guard card.minX < r.maxX, r.minX < card.maxX, card.minY < r.maxY, r.minY < card.maxY else { continue }
        let distance = keep ? -1 : abs(r.midX - px)
        if best == nil || distance < best!.distance { best = (SplitDropTarget(tabId: tabId, side: side), distance) }
      }
    }
    return best?.target
  }
}
