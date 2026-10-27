import Foundation

@MainActor
public final class EdgePeek {
  public static let slideMs: Double = 180
  public static let hideDelayMs: Double = 120

  public private(set) var live = false
  public private(set) var enabled: Bool
  public let arc: Bool
  public var held: () -> Bool = { false }
  public var onSlideOut: () -> Void = {}
  public var onLive: (Bool) -> Void = { _ in }
  public var animate: (_ to: Double, _ curve: DockAnimator.Curve, _ done: @escaping () -> Void) -> Void = { _, _, done in done() }
  public var schedule: (_ seconds: Double, _ run: @escaping @MainActor () -> Void) -> AnyObject? = { seconds, run in
    let item = DispatchWorkItem { MainActor.assumeIsolated { run() } }
    DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: item)
    return item
  }
  public var cancel: (AnyObject) -> Void = { ($0 as? DispatchWorkItem)?.cancel() }

  private var hideTimer: AnyObject?
  private var heldBack = false
  private var generation = 0

  public init(enabled: Bool, arc: Bool) {
    self.enabled = enabled
    self.arc = arc
  }

  public static func curve(to: Double, arc: Bool) -> DockAnimator.Curve {
    if arc { return to > 0 ? .spring(.arcPeek) : .timed(duration: DockMotion.arcPeekOutMs / 1000, ease: .inOutCubic) }
    return .timed(duration: slideMs / 1000, ease: .outCubic)
  }

  public func show() {
    clearHide()
    heldBack = false
    guard enabled else { return }
    setLive(true)
    run(to: 1, done: nil)
  }

  public func hide() {
    clearHide()
    hideTimer = schedule(Self.hideDelayMs / 1000) { [weak self] in
      guard let self else { return }
      self.hideTimer = nil
      self.heldBack = self.held()
      if !self.heldBack { self.slideOut() }
    }
  }

  public func recheck() {
    guard heldBack, !held() else { return }
    heldBack = false
    hide()
  }

  public func setEnabled(_ next: Bool) {
    guard next != enabled else { return }
    enabled = next
    guard !next else { return }
    clearHide()
    if live { slideOut() }
  }

  public func stop() {
    clearHide()
    generation += 1
  }

  private func slideOut() {
    onSlideOut()
    run(to: 0) { [weak self] in self?.setLive(false) }
  }

  private func run(to target: Double, done: (() -> Void)?) {
    generation += 1
    let mine = generation
    animate(target, Self.curve(to: target, arc: arc)) { [weak self] in
      guard let self, self.generation == mine else { return }
      done?()
    }
  }

  private func setLive(_ next: Bool) {
    guard next != live else { return }
    live = next
    onLive(next)
  }

  private func clearHide() {
    if let hideTimer { cancel(hideTimer) }
    hideTimer = nil
  }
}
