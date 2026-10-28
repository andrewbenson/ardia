import AppKit

@MainActor
final class StripDropZone: TabDropZone {
  private weak var strip: TopStripView?

  init(strip: TopStripView) { self.strip = strip }

  func aim(_ session: TabDragSession, at windowPoint: CGPoint) -> TabDropAim? {
    guard session.sourceWindow != strip?.windowId, let page = strip?.current, case .some(let beforeId) = page.incoming(at: windowPoint) else { return nil }
    return .insert(beforeId: beforeId)
  }

  func clear() { _ = strip?.current?.incoming(at: nil) }

  func drop(_ session: TabDragSession, _ aim: TabDropAim) -> Bool {
    guard let strip, case .insert(let beforeId) = aim, let bridge = strip.dragBridge else { return false }
    let landed = bridge.land(ids: session.tabIds, from: session.sourceWindow, in: strip.windowId, beforeId: beforeId)
    strip.current?.endIncoming()
    return landed
  }
}
