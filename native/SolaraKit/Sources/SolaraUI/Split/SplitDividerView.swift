import AppKit

@MainActor
final class SplitDividerView: NSView {
  static let reach: CGFloat = 2
  static let grabberLength: CGFloat = 36
  static let grabberThickness: CGFloat = 4

  var divider: SplitDivider? {
    didSet {
      guard divider?.vertical != oldValue?.vertical else { return }
      window?.invalidateCursorRects(for: self)
      needsLayout = true
    }
  }
  var dark = false { didSet { if dark != oldValue { paint() } } }
  var onBegin: (() -> Void)?
  var onMove: ((CGFloat) -> Void)?
  var onEnd: (() -> Void)?
  private(set) var hovered = false
  private(set) var dragging = false
  private let grabber = CALayer()
  private var start: NSPoint?

  override var isFlipped: Bool { true }

  override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
    grabber.cornerRadius = 2
    grabber.actions = ["opacity": NSNull(), "bounds": NSNull(), "position": NSNull(), "backgroundColor": NSNull()]
    grabber.opacity = 0
    layer?.addSublayer(grabber)
    paint()
  }

  required init?(coder: NSCoder) { fatalError() }

  static func frame(for divider: SplitDivider) -> CGRect {
    let r = divider.rect
    return divider.vertical ? r.insetBy(dx: -reach, dy: 0) : r.insetBy(dx: 0, dy: -reach)
  }

  override func layout() {
    super.layout()
    let vertical = divider?.vertical ?? true
    let size = vertical ? CGSize(width: Self.grabberThickness, height: Self.grabberLength) : CGSize(width: Self.grabberLength, height: Self.grabberThickness)
    grabber.frame = CGRect(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2, width: size.width, height: size.height)
  }

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    for area in trackingAreas { removeTrackingArea(area) }
    addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
  }

  override func resetCursorRects() {
    addCursorRect(bounds, cursor: divider?.vertical ?? true ? .resizeLeftRight : .resizeUpDown)
  }

  override func mouseEntered(with event: NSEvent) {
    hovered = true
    paint()
  }

  override func mouseExited(with event: NSEvent) {
    hovered = false
    paint()
  }

  override func mouseDown(with event: NSEvent) {
    start = event.locationInWindow
    dragging = true
    paint()
    onBegin?()
  }

  override func mouseDragged(with event: NSEvent) {
    guard let start else { return }
    let at = event.locationInWindow
    onMove?(divider?.vertical ?? true ? at.x - start.x : start.y - at.y)
  }

  override func mouseUp(with event: NSEvent) {
    guard start != nil else { return }
    start = nil
    dragging = false
    paint()
    onEnd?()
  }

  private func paint() {
    grabber.backgroundColor = (dark ? NSColor.white : NSColor.black).cgColor
    grabber.opacity = dragging ? 0.55 : hovered ? 0.32 : 0
  }
}
