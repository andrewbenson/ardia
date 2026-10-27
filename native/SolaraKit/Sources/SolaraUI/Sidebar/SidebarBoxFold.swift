import AppKit
import QuartzCore
import SolaraModel

@MainActor
protocol SidebarFoldingBox: NSView {
  var fill: CALayer { get }
}

extension SidebarFoldingBox {
  func fold(to frame: NSRect, motion: SidebarMotion) {
    guard let host = superview?.layer, let container = fill.superlayer else {
      self.frame = frame
      return
    }
    let shownContainer = container.presentation() ?? container
    let shown = host.convert((fill.presentation() ?? fill).frame, from: shownContainer)
    self.frame = frame
    needsLayout = true
    layoutSubtreeIfNeeded()
    let from = container.convert(shown, from: host)
    let to = fill.frame
    let bounds = CABasicAnimation(keyPath: "bounds.size")
    bounds.fromValue = NSValue(size: from.size)
    bounds.toValue = NSValue(size: to.size)
    let position = CABasicAnimation(keyPath: "position")
    position.fromValue = NSValue(point: CGPoint(x: from.midX, y: from.midY))
    position.toValue = NSValue(point: fill.position)
    let group = CAAnimationGroup()
    group.animations = [bounds, position]
    group.duration = motion.slide
    group.timingFunction = motion.slideCurve
    fill.add(group, forKey: "fold")
  }

  var shownHeight: Double { Double((fill.presentation() ?? fill).bounds.height) }
}

extension SidebarMotion {
  static func folding(_ previous: BrowserState, _ next: BrowserState, windowId: String) -> Bool {
    guard previous.groups.version != next.groups.version else { return false }
    return next.groups.values.contains { group in
      group.windowId == windowId && previous.groups[group.id].map { $0.collapsed != group.collapsed } == true
    }
  }
}

extension GroupBoxView: SidebarFoldingBox {}
extension LiveBoxView: SidebarFoldingBox {}
