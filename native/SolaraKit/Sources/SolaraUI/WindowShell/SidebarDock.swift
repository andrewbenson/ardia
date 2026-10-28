import AppKit
import QuartzCore

public struct SidebarDockState: Decodable, Equatable, Sendable {
  public var open: Bool
  public var arc: Bool
  public var fullscreen: Bool
  public var topTabs: Bool
  public var width: Double
  public var held: Bool
  public var slideSwitch: Bool
  public var lights: [Double]
  public var look: StripPeekLook

  public init(
    open: Bool = true, arc: Bool = false, fullscreen: Bool = false, topTabs: Bool = false, width: Double = Double(ShellMetrics.sidebarWidth),
    held: Bool = false, slideSwitch: Bool = true,
    lights: [Double] = [Double(ShellMetrics.lightsCenter.x), Double(ShellMetrics.lightsCenter.y)],
    look: StripPeekLook = StripPeekLook(fill: "#202020", border: "#FFFFFF1A", shadowOpacity: 0.3)
  ) {
    self.open = open
    self.arc = arc
    self.fullscreen = fullscreen
    self.topTabs = topTabs
    self.width = width
    self.held = held
    self.slideSwitch = slideSwitch
    self.lights = lights
    self.look = look
  }
}

@MainActor
public final class SidebarDockPanel: NSView {
  public let chrome = StripPeekPanel()
  public let clip = FlippedContainerView()

  public override var isFlipped: Bool { true }

  public override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
    layer?.masksToBounds = false
    clip.wantsLayer = true
    clip.layer?.cornerRadius = ShellMetrics.peekRadius
    clip.layer?.cornerCurve = .continuous
    clip.layer?.masksToBounds = true
    addSubview(chrome)
    addSubview(clip)
  }

  required init?(coder: NSCoder) { fatalError() }

  public var content: NSView? { clip.subviews.first }

  public func hold(_ view: NSView) {
    guard view.superview !== clip else { return }
    view.removeFromSuperview()
    view.autoresizingMask = []
    clip.addSubview(view)
    needsLayout = true
  }

  public override func hitTest(_ point: NSPoint) -> NSView? {
    let hit = super.hitTest(point)
    return hit === self || hit === clip || hit === chrome ? nil : hit
  }

  public override func layout() {
    super.layout()
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    chrome.frame = bounds
    clip.frame = bounds
    for view in clip.subviews where view.frame != clip.bounds { view.frame = clip.bounds }
    CATransaction.commit()
  }

  public override func setFrameSize(_ newSize: NSSize) {
    super.setFrameSize(newSize)
    needsLayout = true
  }
}

@MainActor
public final class SidebarDock {
  public let shell: WindowShellView
  public let panel = SidebarDockPanel()
  public private(set) var state: SidebarDockState
  public private(set) var peek: EdgePeek
  public var column: () -> NSView? = { nil }
  public var onWatch: (_ hold: CGFloat?) -> Void = { _ in }
  public var onLights: (CGPoint?) -> Void = { _ in }
  public var onDock: (_ value: Double, _ moving: Bool) -> Void = { _, _ in }
  public var onPeek: (_ live: Bool, _ right: Double) -> Void = { _, _ in }
  public var onSlideOut: () -> Void = {}
  public var reduceMotion: () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

  private var toggle: DockToggle
  private let dock: DockAnimator
  private let slide = DockAnimator(value: 0)
  private var slideDone: (() -> Void)?
  private var edgeOver = false
  private var watching: CGFloat?
  private var sentLights: CGPoint??
  private var stopped = false

  public init(shell: WindowShellView, state: SidebarDockState) {
    self.shell = shell
    self.state = state
    toggle = DockToggle(open: state.open)
    dock = DockAnimator(value: state.open ? 1 : 0)
    peek = EdgePeek(enabled: false, arc: state.arc)
    panel.chrome.apply(state.look)
    dock.onChange = { [weak self] _ in self?.dockMoved() }
    dock.onSettle = { [weak self] _ in self?.dockSettled() }
    slide.onChange = { [weak self] _ in self?.slideMoved() }
    slide.onSettle = { [weak self] _ in
      let done = self?.slideDone
      self?.slideDone = nil
      done?()
    }
    wire(peek)
    shell.update {
      $0.dock = CGFloat(dock.value)
      $0.away = toggle.away
      $0.peeking = false
      $0.peekSlide = 0
    }
  }

  public func start() {
    guard !stopped else { return }
    refresh()
  }

  public var dockValue: Double { dock.value }
  public var slideValue: Double { slide.value }
  public var moving: Bool { toggle.moving }
  public var sliding: Bool { slide.moving }
  public var watchingHold: CGFloat? { watching }

  public func apply(_ next: SidebarDockState) {
    guard !stopped, next != state else { return }
    let was = state
    state = next
    if next.look != was.look { panel.chrome.apply(next.look) }
    if next.arc != was.arc { rebuildPeek() }
    if next.open != was.open { toggleTo(next.open) }
    if was.held && !next.held { peek.recheck() }
    syncPeek()
    refresh()
  }

  public func edge(over: Bool) {
    guard !stopped else { return }
    edgeOver = over
    if over { peek.show() } else { peek.hide() }
  }

  public func step(by seconds: Double) {
    dock.step(by: seconds)
    slide.step(by: seconds)
  }

  public func stop() {
    guard !stopped else { return }
    stopped = true
    dock.stop()
    slide.stop()
    peek.stop()
    returnColumn()
    setWatch(nil)
    onLights(nil)
  }

  private func wire(_ peek: EdgePeek) {
    peek.held = { [weak self] in
      guard let self else { return false }
      return self.edgeOver || self.state.held
    }
    peek.onSlideOut = { [weak self] in self?.onSlideOut() }
    peek.onLive = { [weak self] live in self?.peekLive(live) }
    peek.animate = { [weak self] to, curve, done in
      guard let self else { return done() }
      if !self.slide.moving && self.slide.value == to { return done() }
      self.slideDone = done
      self.slide.animate(to: to, curve: curve, in: self.shell)
    }
  }

  private func rebuildPeek() {
    let wasLive = peek.live
    peek.stop()
    if wasLive {
      slide.jump(to: 0)
      peekLive(false)
    }
    peek = EdgePeek(enabled: false, arc: state.arc)
    wire(peek)
  }

  private func toggleTo(_ open: Bool) {
    let options = DockToggle.Options(
      animate: !state.fullscreen, reduceMotion: reduceMotion(), slideSwitch: state.slideSwitch, arc: state.arc, peekShown: peek.live)
    switch toggle.set(open: open, options) {
    case .none:
      return
    case .jump(let to):
      dock.jump(to: to)
      dockSettled()
    case .run(let to, let curve):
      shell.update { $0.away = false }
      onDock(dock.value, true)
      dock.animate(to: to, curve: curve, in: shell)
    }
  }

  private func dockMoved() {
    shell.update { $0.dock = CGFloat(dock.value) }
    if toggle.moving { onDock(dock.value, true) }
    sendLights()
  }

  private func dockSettled() {
    toggle.settled()
    shell.update { $0.dock = CGFloat(dock.value) }
    syncPeek()
    onDock(dock.value, false)
    refresh()
  }

  private var awayNow: Bool { state.fullscreen || (!state.open && !toggle.moving && !peek.live) }

  private var peeking: Bool { peek.live && !state.open && !state.fullscreen }

  private func peekLive(_ live: Bool) {
    syncPeek()
    onPeek(live, Double(ShellMetrics.peekOrigin.x) + state.width)
    refresh()
  }

  private func syncPeek() {
    if peeking { borrowColumn() } else { returnColumn() }
    shell.update {
      $0.peeking = peeking
      $0.peekSlide = CGFloat(slide.value)
      $0.away = awayNow
    }
  }

  private func slideMoved() {
    shell.update { $0.peekSlide = CGFloat(slide.value) }
    panel.alphaValue = state.arc ? 1 : CGFloat(slide.value)
    sendLights()
  }

  private func borrowColumn() {
    guard panel.content == nil, let column = column() else { return }
    if shell.view(in: .sidebar) === column { shell.mount(.sidebar, nil) }
    panel.hold(column)
    panel.alphaValue = state.arc ? 1 : CGFloat(slide.value)
    shell.mount(.sidebar, panel)
    placePanel()
  }

  private func returnColumn() {
    guard panel.superview != nil || panel.content != nil else { return }
    let column = panel.content
    if shell.view(in: .sidebar) === panel { shell.mount(.sidebar, nil) }
    panel.removeFromSuperview()
    panel.alphaValue = 1
    if let column {
      column.removeFromSuperview()
      shell.mount(.sidebar, column)
    }
  }

  private func placePanel() {
    panel.needsLayout = true
    panel.layoutSubtreeIfNeeded()
  }

  private func refresh() {
    peek.setEnabled(!state.open && !toggle.moving && !state.fullscreen && !state.topTabs)
    let watch = !state.open && !state.fullscreen && !toggle.moving && !state.topTabs
    let hold = peek.live ? ShellMetrics.peekOrigin.x + CGFloat(state.width) + ShellMetrics.holdSlack : ShellMetrics.edgeStripWidth
    setWatch(watch ? hold : nil)
    sendLights()
  }

  private func setWatch(_ hold: CGFloat?) {
    guard hold != watching else { return }
    watching = hold
    if hold == nil { edgeOver = false }
    onWatch(hold)
  }

  private func sendLights() {
    guard !state.topTabs else { return sendStripLights() }
    let base = CGPoint(x: state.lights.first ?? Double(ShellMetrics.lightsCenter.x), y: state.lights.last ?? Double(ShellMetrics.lightsCenter.y))
    let width = CGFloat(state.width)
    let offset: CGFloat = state.fullscreen
      ? 0
      : peeking ? (width + 12) * CGFloat(1 - slide.value) - ShellMetrics.peekOrigin.x : width * CGFloat(1 - dock.value)
    let center = DockMotion.lightsCenter(offset: offset, down: peeking ? ShellMetrics.peekOrigin.y : 0, base: base)
    send(center)
  }

  private func sendStripLights() {
    guard toggle.moving, !state.fullscreen else { return }
    let travel = ShellInset.topTabs.top
    let up = DockMotion.jsRound(travel * CGFloat(1 - dock.value) * 2) / 2
    send(CGPoint(x: ShellMetrics.topStripLightsCenter.x, y: ShellMetrics.topStripLightsCenter.y - up))
  }

  private func send(_ center: CGPoint?) {
    if let sentLights, sentLights == center { return }
    sentLights = .some(center)
    onLights(center)
  }
}
