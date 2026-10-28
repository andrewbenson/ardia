import AppKit

public final class HoverPlayerCardView: NSView {
  public let player = MiniPlayerView()
  public var onPointer: ((Bool) -> Void)?
  public private(set) var state: MediaPlayerState?
  private var tracking: NSTrackingArea?
  private var inside = false

  public override var isFlipped: Bool { true }

  public override init(frame: NSRect) {
    super.init(frame: NSRect(x: 0, y: 0, width: MiniPlayerView.width, height: MiniPlayerView.height))
    player.frame = bounds
    addSubview(player)
    DevPointer.observe(self, #selector(devPointer(_:)))
  }

  public convenience init() { self.init(frame: .zero) }

  required init?(coder: NSCoder) { fatalError() }

  public func set(_ next: MediaPlayerState) {
    state = next
    player.update(next)
  }

  public override func updateTrackingAreas() {
    super.updateTrackingAreas()
    if let tracking { removeTrackingArea(tracking) }
    let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
    addTrackingArea(area)
    tracking = area
  }

  public override func mouseEntered(with event: NSEvent) { pointer(true) }
  public override func mouseExited(with event: NSEvent) { pointer(false) }

  public override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    if window == nil { pointer(false) }
  }

  @objc private func devPointer(_ note: Notification) { pointer(DevPointer.inside(self, note)) }

  private func pointer(_ on: Bool) {
    guard on != inside else { return }
    inside = on
    onPointer?(on)
  }
}
