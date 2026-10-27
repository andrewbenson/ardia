import AppKit

@MainActor
public final class WindowShellView: NSView {
  public enum Slot: String, CaseIterable, Sendable {
    case backdrop
    case react
    case card
    case splitChrome
    case peek
    case sidebar
    case topStrip
    case overlay
  }

  public let windowId: String
  public private(set) var input: DockedLayoutInput
  public private(set) var frames: DockedLayoutFrames
  public var onFrames: ((DockedLayoutFrames) -> Void)?
  public var onDetach: (() -> Void)?
  private var mounted: [Slot: NSView] = [:]

  public override var isFlipped: Bool { true }

  public init(windowId: String) {
    self.windowId = windowId
    input = DockedLayoutInput(size: .zero, dock: 1)
    frames = DockedLayoutFrames.of(input)
    super.init(frame: .zero)
    wantsLayer = true
  }

  required init?(coder: NSCoder) { fatalError() }

  public func view(in slot: Slot) -> NSView? { mounted[slot] }

  @objc public var backgroundColor: NSColor? {
    get {
      guard let react = mounted[.react], react.responds(to: Selector(("backgroundColor"))) else { return nil }
      return react.value(forKey: "backgroundColor") as? NSColor
    }
    set {
      guard let react = mounted[.react], react.responds(to: Selector(("setBackgroundColor:"))) else { return }
      react.setValue(newValue, forKey: "backgroundColor")
    }
  }

  public func mount(_ slot: Slot, _ view: NSView?) {
    if let current = mounted[slot], current === view { return }
    mounted[slot]?.removeFromSuperview()
    mounted[slot] = view
    guard let view else { return }
    view.autoresizingMask = []
    let above = Slot.allCases.drop { $0 != slot }.dropFirst().lazy.compactMap { self.mounted[$0] }.first { $0.superview === self }
    if let above { addSubview(view, positioned: .below, relativeTo: above) } else { addSubview(view) }
    place(slot, view)
  }

  public func update(_ change: (inout DockedLayoutInput) -> Void) {
    var next = input
    change(&next)
    guard next != input else { return }
    input = next
    relayout()
  }

  public override func setFrameSize(_ newSize: NSSize) {
    super.setFrameSize(newSize)
    relayout()
  }

  public override func layout() {
    super.layout()
    relayout()
  }

  public override func viewDidMoveToSuperview() {
    super.viewDidMoveToSuperview()
    if superview == nil { onDetach?() }
  }

  public override func hitTest(_ point: NSPoint) -> NSView? {
    let hit = super.hitTest(point)
    return hit === self ? nil : hit
  }

  private func relayout() {
    input.size = bounds.size
    let next = DockedLayoutFrames.of(input)
    let changed = next != frames
    frames = next
    for (slot, view) in mounted { place(slot, view) }
    if changed { onFrames?(next) }
  }

  private func place(_ slot: Slot, _ view: NSView) {
    let frame: CGRect
    switch slot {
    case .backdrop, .react, .overlay: frame = bounds
    case .card, .splitChrome, .peek: frame = frames.card
    case .sidebar: frame = (frames.sidebar ?? .zero).offsetBy(dx: frames.sidebarShift, dy: 0)
    case .topStrip: frame = frames.topStrip ?? .zero
    }
    if view.frame != frame { view.frame = frame }
    view.isHidden = (slot == .sidebar && frames.sidebar == nil) || (slot == .topStrip && frames.topStrip == nil)
  }
}
