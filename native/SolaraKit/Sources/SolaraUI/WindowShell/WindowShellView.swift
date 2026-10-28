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

  public static let hoverCoverChanged = Notification.Name("ArdiaHoverCoverChanged")

  public let windowId: String
  public private(set) var input: DockedLayoutInput
  public private(set) var frames: DockedLayoutFrames
  public var onFrames: ((DockedLayoutFrames) -> Void)?
  public var onDetach: (() -> Void)?
  public var onWindow: ((NSWindow?) -> Void)?
  public let card = FlippedContainerView()
  private var mounted: [Slot: NSView] = [:]
  private var pointerLayer: ObjectIdentifier?

  public override var isFlipped: Bool { true }

  public init(windowId: String) {
    self.windowId = windowId
    input = DockedLayoutInput(size: .zero, dock: 1)
    frames = DockedLayoutFrames.of(input)
    super.init(frame: .zero)
    wantsLayer = true
    addTrackingArea(NSTrackingArea(rect: .zero, options: [.activeAlways, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect], owner: self, userInfo: nil))
    mount(.card, card)
  }

  required init?(coder: NSCoder) { fatalError() }

  public func view(in slot: Slot) -> NSView? { mounted[slot] }

  @objc public var backgroundColor: NSColor?
  @objc public var drawsWholeWindow: Bool { true }

  public func mount(_ slot: Slot, _ view: NSView?) {
    precondition(slot != .card || view === card, "page views attach inside the card container")
    if let current = mounted[slot], current === view, current.superview === self { return }
    if let current = mounted[slot], current.superview === self, current !== view { current.removeFromSuperview() }
    if let view, let other = mounted.first(where: { $0.key != slot && $0.value === view })?.key { mounted[other] = nil }
    mounted[slot] = view
    defer { coverChanged() }
    guard let view else { return }
    view.autoresizingMask = []
    if slot == .react, view.responds(to: Selector(("setBackgroundColor:"))) { view.setValue(nil, forKey: "backgroundColor") }
    let above = Slot.allCases.drop { $0 != slot }.dropFirst().lazy.compactMap { self.mounted[$0] }.first { $0.superview === self }
    let foreign = subviews.first { subview in subview !== view && !mounted.values.contains { $0 === subview } }
    if let above = above ?? foreign { addSubview(view, positioned: .below, relativeTo: above) } else { addSubview(view) }
    place(slot, view)
  }

  public func slot(of view: NSView) -> Slot? { mounted.first { $0.value === view }?.key }

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

  public override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    onWindow?(window)
  }

  public override func viewDidMoveToSuperview() {
    super.viewDidMoveToSuperview()
    if superview == nil { onDetach?() }
  }

  public override func hitTest(_ point: NSPoint) -> NSView? {
    let hit = super.hitTest(point)
    return hit === self ? nil : hit
  }

  public override func mouseMoved(with event: NSEvent) {
    notePointer(event.locationInWindow)
    super.mouseMoved(with: event)
  }
  public override func mouseEntered(with event: NSEvent) { notePointer(event.locationInWindow) }
  public override func mouseExited(with event: NSEvent) { notePointer(nil) }

  public func slotUnderPointer(at pointInWindow: NSPoint) -> Slot? {
    layerUnderPointer(at: pointInWindow).flatMap(slot(of:))
  }

  private func layerUnderPointer(at pointInWindow: NSPoint) -> NSView? {
    let point = convert(pointInWindow, from: nil)
    for layer in subviews.reversed() where !layer.isHidden {
      if layer === mounted[.react] { return layer.frame.contains(point) ? layer : nil }
      if layer.hitTest(point) != nil { return layer }
    }
    return nil
  }

  private func notePointer(_ pointInWindow: NSPoint?) {
    let layer = pointInWindow.flatMap(layerUnderPointer(at:)).map(ObjectIdentifier.init)
    guard layer != pointerLayer else { return }
    pointerLayer = layer
    coverChanged()
  }

  private func coverChanged() {
    NotificationCenter.default.post(name: Self.hoverCoverChanged, object: self)
  }

  private func relayout() {
    input.size = bounds.size
    let next = DockedLayoutFrames.of(input)
    let changed = next != frames
    frames = next
    for (slot, view) in mounted { place(slot, view) }
    if changed {
      coverChanged()
      onFrames?(next)
    }
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

@MainActor
public final class FlippedContainerView: NSView {
  public override var isFlipped: Bool { true }

  public override func hitTest(_ point: NSPoint) -> NSView? {
    let hit = super.hitTest(point)
    return hit === self ? nil : hit
  }
}
