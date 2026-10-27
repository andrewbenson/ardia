import AppKit
import QuartzCore

@MainActor
public final class DockAnimator {
  public enum Curve: Equatable, Sendable {
    case spring(ShellSpring)
    case timed(duration: Double, ease: TimedRun.Ease)
  }

  public private(set) var value: Double
  public private(set) var target: Double
  public var onChange: ((Double) -> Void)?
  public var onSettle: ((Double) -> Void)?
  public var now: () -> CFTimeInterval = CACurrentMediaTime

  private var curve: Curve = .spring(.dock)
  private var start: Double = 0
  private var velocity: Double = 0
  private var launchVelocity: Double = 0
  private var elapsed: Double = 0
  private var last: CFTimeInterval = 0
  private var link: CADisplayLink?

  public var moving: Bool { link != nil }

  public init(value: Double) {
    self.value = value
    target = value
  }

  public func jump(to value: Double) {
    stopLink()
    self.value = value
    target = value
    velocity = 0
    onChange?(value)
  }

  public func animate(to target: Double, curve: Curve = .spring(.dock), in view: NSView) {
    guard target != self.target || moving else { return }
    self.target = target
    self.curve = curve
    start = value
    launchVelocity = velocity
    elapsed = 0
    last = now()
    if link == nil {
      let made = view.displayLink(target: self, selector: #selector(tick(_:)))
      made.add(to: .main, forMode: .common)
      link = made
    }
  }

  public func step(by seconds: Double) {
    elapsed += min(seconds, DockMotion.maxStep)
    let done: Bool
    switch curve {
    case .spring(let spring):
      let sample = SpringRun(from: start, to: target, spring: spring, initialVelocity: launchVelocity).sample(elapsed)
      value = sample.value
      velocity = sample.done ? 0 : sample.velocity
      done = sample.done
    case .timed(let duration, let ease):
      let sample = TimedRun(from: start, to: target, duration: duration, ease: ease).sample(elapsed)
      value = sample.value
      velocity = 0
      done = sample.done
    }
    onChange?(value)
    if done {
      stopLink()
      onSettle?(value)
    }
  }

  @objc private func tick(_ link: CADisplayLink) {
    let t = now()
    let dt = t - last
    last = t
    step(by: dt)
  }

  private func stopLink() {
    link?.invalidate()
    link = nil
  }

  public func stop() { stopLink() }
}
