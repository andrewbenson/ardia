import AppKit

@MainActor
public final class WindowShellView: NSView {
  public enum Slot: String, CaseIterable, Sendable {
    case backdrop
    case tint
    case react
    case card
    case splitChrome
    case peek
    case sidebar
    case topStrip
    case overlay

    static let reactOnTop: [Slot] = [.backdrop, .tint, .card, .splitChrome, .peek, .sidebar, .topStrip, .react, .overlay]
  }

  public static let hoverCoverChanged = Notification.Name("ArdiaHoverCoverChanged")

  public let windowId: String
  public let reactOnTop: Bool
  public private(set) var input: DockedLayoutInput
  public private(set) var frames: DockedLayoutFrames
  public var onFrames: ((DockedLayoutFrames) -> Void)?
  public var onDetach: (() -> Void)?
  public var onWindow: ((NSWindow?) -> Void)?
  public let card = FlippedContainerView()
  public let overlay = ShellOverlayView()
  public let hiddenPages = FlippedContainerView()
  public let cardPage = FlippedContainerView()
  public let cardClip = FlippedContainerView()
  public var cardStyle = CardStyle.resting { didSet { if cardStyle != oldValue { applyCardStyle() } } }
  public var cardPageFrame: CGRect? { didSet { if cardPageFrame != oldValue { placeCardPage() } } }
  public var widthDragActive = false
  private var mounted: [Slot: NSView] = [:]
  private var pointerLayer: ObjectIdentifier?
  private var pendingPointer: NSPoint??
  private var lastPointer: NSPoint?
  private var pointerLink: CADisplayLink?
  #if DEBUG
  public var devPointerResolved: ((_ changed: Bool) -> Void)?
  public private(set) var devPointerLookups = 0
  public private(set) var devPointerLookupNanos: UInt64 = 0
  #endif
  private var modalOwners: Set<String> = []
  private weak var titlebarWindow: NSWindow?
  private var titlebarAccessibility: [(button: NSButton, cell: NSCell, accessible: Bool, children: [Any]?)] = []

  public override var isFlipped: Bool { true }

  public init(windowId: String, reactOnTop: Bool = false) {
    self.windowId = windowId
    self.reactOnTop = reactOnTop
    input = DockedLayoutInput(size: .zero, dock: 1)
    frames = DockedLayoutFrames.of(input)
    super.init(frame: .zero)
    wantsLayer = true
    hiddenPages.isHidden = true
    hiddenPages.autoresizingMask = []
    addSubview(hiddenPages)
    addTrackingArea(NSTrackingArea(rect: .zero, options: [.activeAlways, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect], owner: self, userInfo: nil))
    cardPage.autoresizingMask = []
    cardClip.autoresizingMask = []
    cardClip.wantsLayer = true
    cardClip.layer?.masksToBounds = true
    cardClip.layer?.cornerCurve = .continuous
    applyCardStyle()
    cardClip.addSubview(cardPage)
    card.addSubview(cardClip)
    mount(.card, card)
    mount(.overlay, overlay)
    overlay.onChildrenChanged = { [weak self] in self?.coverChanged() }
    DevPointer.observe(self, #selector(devPointer(_:)))
  }

  required init?(coder: NSCoder) { fatalError() }

  public func view(in slot: Slot) -> NSView? { mounted[slot] }

  @objc public var backgroundColor: NSColor?
  @objc public var drawsWholeWindow: Bool { true }
  @objc public var ardia_gatesHover: Bool { true }

  public func mount(_ slot: Slot, _ view: NSView?) {
    if let view, let container = ownedContainer(slot), view !== container {
      assertionFailure("\(slot) is shell-owned: add views inside shell.\(slot), don't mount them")
      NSLog("WindowShellView: a view was mounted in the shell-owned \(slot.rawValue) slot; it goes inside the container instead")
      view.removeFromSuperview()
      container.addSubview(view)
      return
    }
    if view == nil, ownedContainer(slot) != nil { return }
    if let current = mounted[slot], current === view, current.superview === self { return }
    if let current = mounted[slot], current.superview === self, current !== view { current.removeFromSuperview() }
    if let view, let other = mounted.first(where: { $0.key != slot && $0.value === view })?.key { mounted[other] = nil }
    mounted[slot] = view
    defer { coverChanged() }
    guard let view else { return }
    view.autoresizingMask = []
    if slot == .react, view.responds(to: Selector(("setBackgroundColor:"))) { view.setValue(nil, forKey: "backgroundColor") }
    let above = stack.drop { $0 != slot }.dropFirst().lazy.compactMap { self.mounted[$0] }.first { $0.superview === self }
    let foreign = subviews.first { subview in subview !== view && subview !== hiddenPages && !mounted.values.contains { $0 === subview } }
    if let above = above ?? foreign { addSubview(view, positioned: .below, relativeTo: above) } else { addSubview(view) }
    place(slot, view)
  }

  private var stack: [Slot] { reactOnTop ? Slot.reactOnTop : Slot.allCases }

  private func ownedContainer(_ slot: Slot) -> NSView? {
    switch slot {
    case .card: card
    case .overlay: overlay
    default: nil
    }
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
    if window == nil { TabSlots.shared.remove(.card(windowId), container: cardPage) } else { TabSlots.shared.set(.card(windowId), container: cardPage) }
    if window == nil { stopPointerLink() }
    syncTitlebarAccessibility()
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

  public var modalShown: Bool { !modalOwners.isEmpty }

  public func setModal(_ owner: String, shown: Bool) {
    let before = modalShown
    if shown { modalOwners.insert(owner) } else { modalOwners.remove(owner) }
    guard modalShown != before else { return }
    syncTitlebarAccessibility()
    NSAccessibility.post(element: self, notification: .layoutChanged)
  }

  private func syncTitlebarAccessibility() {
    for entry in titlebarAccessibility {
      entry.cell.setAccessibilityElement(entry.accessible)
      entry.button.setAccessibilityChildren(entry.children)
    }
    if let titlebarWindow { NSAccessibility.post(element: titlebarWindow, notification: .layoutChanged) }
    titlebarAccessibility.removeAll()
    titlebarWindow = nil
    guard modalShown, let window else { return }
    titlebarWindow = window
    for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
      guard let button = window.standardWindowButton(kind), let cell = button.cell else { continue }
      titlebarAccessibility.append((button, cell, cell.isAccessibilityElement(), button.accessibilityChildren()))
      cell.setAccessibilityElement(false)
      button.setAccessibilityChildren([])
    }
    NSAccessibility.post(element: window, notification: .layoutChanged)
  }

  private var modalLayers: [NSView]? {
    guard modalShown, let root = mounted[.react], root.superview === self else { return nil }
    return overlay.superview === self && !overlay.isHidden ? [root, overlay] : [root]
  }

  public override func accessibilityChildren() -> [Any]? {
    guard let modalLayers else { return super.accessibilityChildren() }
    return NSAccessibility.unignoredChildren(from: modalLayers)
  }

  public override func accessibilityHitTest(_ point: NSPoint) -> Any? {
    guard let modalLayers, let root = modalLayers.first else { return super.accessibilityHitTest(point) }
    if modalLayers.contains(where: { $0 === overlay }), let window, overlay.hitTest(convert(window.convertPoint(fromScreen: point), from: nil)) != nil {
      return overlay.accessibilityHitTest(point)
    }
    return root.accessibilityHitTest(point)
  }

  public override func mouseMoved(with event: NSEvent) { notePointer(event.locationInWindow) }
  public override func mouseEntered(with event: NSEvent) { notePointer(event.locationInWindow) }
  public override func mouseExited(with event: NSEvent) { notePointer(nil) }

  public func coverChanged() {
    if reactOnTop, let pointerLink {
      pendingPointer = .some(lastPointer)
      pointerLink.isPaused = false
      return postCoverChanged()
    }
    if !resolvePointer(lastPointer) { postCoverChanged() }
  }

  private func postCoverChanged() {
    NotificationCenter.default.post(name: Self.hoverCoverChanged, object: self)
  }

  public var pointerSlot: Slot? {
    pointerLayer.flatMap { layer in mounted.first { ObjectIdentifier($0.value) == layer }?.key }
  }

  public func slotUnderPointer(at pointInWindow: NSPoint) -> Slot? {
    layerUnderPointer(at: pointInWindow).flatMap(slot(of:))
  }

  private func layerUnderPointer(at pointInWindow: NSPoint) -> NSView? {
    let point = convert(pointInWindow, from: nil)
    for layer in subviews.reversed() where !layer.isHidden {
      if layer === mounted[.react], !reactOnTop { return layer.frame.contains(point) ? layer : nil }
      if layer.hitTest(point) != nil { return layer }
    }
    return nil
  }

  @objc private func devPointer(_ note: Notification) {
    guard let window else { return }
    notePointer((note.object as? NSValue).map { window.convertPoint(fromScreen: $0.pointValue) } ?? window.mouseLocationOutsideOfEventStream)
  }

  private func notePointer(_ pointInWindow: NSPoint?) {
    lastPointer = pointInWindow
    guard reactOnTop, window != nil else {
      resolvePointer(pointInWindow)
      return
    }
    if let pointerLink, !pointerLink.isPaused {
      pendingPointer = .some(pointInWindow)
      return
    }
    resolvePointer(pointInWindow)
    if let pointerLink { pointerLink.isPaused = false; return }
    let made = displayLink(target: self, selector: #selector(pointerFrame(_:)))
    made.add(to: .main, forMode: .common)
    pointerLink = made
  }

  @objc private func pointerFrame(_ link: CADisplayLink) {
    guard let pending = pendingPointer else { link.isPaused = true; return }
    pendingPointer = nil
    resolvePointer(pending)
  }

  private func stopPointerLink() {
    pointerLink?.invalidate()
    pointerLink = nil
    pendingPointer = nil
  }

  @discardableResult
  private func resolvePointer(_ pointInWindow: NSPoint?) -> Bool {
    #if DEBUG
    let start = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
    #endif
    let layer = pointInWindow.flatMap(layerUnderPointer(at:)).map(ObjectIdentifier.init)
    let changed = layer != pointerLayer
    #if DEBUG
    devPointerLookups += 1
    devPointerLookupNanos += clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - start
    #endif
    if changed {
      pointerLayer = layer
      postCoverChanged()
    }
    #if DEBUG
    devPointerResolved?(changed)
    #endif
    return changed
  }

  #if DEBUG
  public func devNotePointer(_ pointInWindow: NSPoint?) { notePointer(pointInWindow) }

  public func devPointerFrame() {
    if let pointerLink { pointerFrame(pointerLink) }
  }

  public func devResetPointerStats() {
    devPointerLookups = 0
    devPointerLookupNanos = 0
  }
  #endif

  private func relayout() {
    input.size = bounds.size
    let next = DockedLayoutFrames.of(input)
    let changed = next != frames
    frames = next
    for (slot, view) in mounted { place(slot, view) }
    if hiddenPages.frame != frames.card { hiddenPages.frame = frames.card }
    placeCardPage()
    if changed {
      coverChanged()
      onFrames?(next)
    }
  }

  private func applyCardStyle() {
    cardClip.layer?.cornerRadius = cardStyle.radius
    cardClip.layer?.backgroundColor = cardStyle.fill?.cgColor
  }

  private func placeCardPage() {
    let clip = CGRect(origin: .zero, size: frames.card.size)
    if cardClip.frame != clip { cardClip.frame = clip }
    let top = min(ShellMetrics.toolbarHeight, frames.card.height)
    let frame = cardPageFrame ?? CGRect(x: 0, y: top, width: frames.card.width, height: frames.card.height - top)
    if cardPage.frame != frame { cardPage.frame = frame }
  }

  private func place(_ slot: Slot, _ view: NSView) {
    let frame: CGRect
    switch slot {
    case .backdrop, .tint, .react, .overlay: frame = bounds
    case .card, .splitChrome, .peek: frame = frames.card
    case .sidebar: frame = (frames.sidebar ?? .zero).offsetBy(dx: frames.sidebarShift, dy: 0)
    case .topStrip: frame = frames.topStrip ?? .zero
    }
    if view.frame != frame { view.frame = frame }
    view.isHidden = (slot == .sidebar && frames.sidebar == nil) || (slot == .topStrip && frames.topStrip == nil)
  }
}

public struct CardStyle: Equatable {
  public var fill: NSColor?
  public var radius: CGFloat

  public init(fill: NSColor?, radius: CGFloat) {
    self.fill = fill
    self.radius = radius
  }

  public static var resting: CardStyle { CardStyle(fill: nil, radius: ShellMetrics.cardRadius) }
}

@MainActor
public final class FlippedContainerView: NSView {
  public override var isFlipped: Bool { true }

  public override func hitTest(_ point: NSPoint) -> NSView? {
    let hit = super.hitTest(point)
    return hit === self ? nil : hit
  }
}

@MainActor
public final class ShellOverlayView: NSView {
  public var onChildrenChanged: (() -> Void)?
  private let turn = OverlayTurn()
  private var watches: [ObjectIdentifier: (hidden: NSKeyValueObservation, frame: NSObjectProtocol)] = [:]

  public override var isFlipped: Bool { true }

  public override func hitTest(_ point: NSPoint) -> NSView? {
    let hit = super.hitTest(point)
    return hit === self ? nil : hit
  }

  public override func didAddSubview(_ subview: NSView) {
    super.didAddSubview(subview)
    watch(subview)
    changed()
  }

  public override func willRemoveSubview(_ subview: NSView) {
    super.willRemoveSubview(subview)
    unwatch(subview)
    guard superview != nil else { return }
    changed()
  }

  private func changed() {
    guard let onChildrenChanged else { return }
    turn.post(onChildrenChanged)
  }

  private func watch(_ child: NSView) {
    unwatch(child)
    child.postsFrameChangedNotifications = true
    let turn = turn
    let post = { [weak self] in
      MainActor.assumeIsolated {
        guard let changed = self?.onChildrenChanged else { return }
        turn.post(changed)
      }
    }
    let hidden = child.observe(\.isHidden, options: [.new]) { _, _ in post() }
    let frame = NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: child, queue: nil) { _ in post() }
    watches[ObjectIdentifier(child)] = (hidden, frame)
  }

  private func unwatch(_ child: NSView) {
    guard let watch = watches.removeValue(forKey: ObjectIdentifier(child)) else { return }
    watch.hidden.invalidate()
    NotificationCenter.default.removeObserver(watch.frame)
  }
}

@MainActor
private final class OverlayTurn {
  private var pending = false

  func post(_ changed: @escaping () -> Void) {
    guard !pending else { return }
    pending = true
    DispatchQueue.main.async {
      MainActor.assumeIsolated {
        self.pending = false
        changed()
      }
    }
  }
}
