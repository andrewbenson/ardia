import AppKit
import QuartzCore

public struct MarqueeTiming: Equatable, Sendable {
  public static let speed: Double = 30
  public static let pause: Double = 1.5
  public static let fadeShare: Double = 0.03

  public let overflow: Double
  public let leg: Double

  public init(maxOverflow: Double) {
    overflow = maxOverflow
    leg = maxOverflow / Self.speed
  }

  public var period: Double { 2 * Self.pause + 2 * leg }

  public func progress(at t: Double) -> Double {
    guard overflow >= 1 else { return 0 }
    let x = t.truncatingRemainder(dividingBy: period)
    if x < Self.pause { return 0 }
    if x < Self.pause + leg { return (x - Self.pause) / leg }
    if x < 2 * Self.pause + leg { return 1 }
    return 1 - (x - 2 * Self.pause - leg) / leg
  }

  var keyTimes: [Double] {
    let p = period
    return [0, Self.pause / p, (Self.pause + leg) / p, (2 * Self.pause + leg) / p, 1]
  }

  func edgeKeys(leading: Bool) -> (times: [Double], values: [Double]) {
    let p = period
    let f = Self.fadeShare * leg
    let outStart = 2 * Self.pause + leg
    if leading {
      return ([0, Self.pause / p, (Self.pause + f) / p, (outStart + leg - f) / p, 1], [0, 0, 1, 1, 0])
    }
    return ([0, (Self.pause + leg - f) / p, (Self.pause + leg) / p, (outStart + f) / p, 1], [1, 1, 0, 0, 1])
  }
}

@MainActor
final class MarqueeGroup {
  private var labels: [MarqueeLabel] = []
  private var resetKey = ""
  private var running: MarqueeTiming?
  private var startedAt: CFTimeInterval = 0

  func add(_ label: MarqueeLabel) {
    labels.append(label)
    label.group = self
  }

  func reset(_ key: String) {
    guard key != resetKey else { return }
    resetKey = key
    running = nil
    restart()
  }

  func restart() {
    let max = labels.map(\.overflow).max() ?? 0
    let timing = MarqueeTiming(maxOverflow: max)
    if let running, running == timing { return }
    running = timing
    startedAt = CACurrentMediaTime()
    for label in labels { label.run(timing, from: startedAt) }
  }

  func progress(at time: CFTimeInterval = CACurrentMediaTime()) -> Double {
    running?.progress(at: time - startedAt) ?? 0
  }
}

final class MarqueeLabel: NSView {
  static let fade: CGFloat = 12
  static let fadeSteps = 8

  private let mover = CALayer()
  private let text = CATextLayer()
  private let leading = CALayer()
  private let trailing = CALayer()
  weak var group: MarqueeGroup?
  private(set) var overflow: Double = 0
  private var natural: CGFloat = 0
  private var attributed = NSAttributedString()
  private var background: (Double, Double, Double) = (0, 0, 0)

  override var isFlipped: Bool { true }

  override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
    layer?.masksToBounds = true
    for l in [mover, text, leading, trailing] as [CALayer] { l.actions = SurfaceLayer.noActions }
    text.truncationMode = .none
    text.isWrapped = false
    mover.addSublayer(text)
    layer?.addSublayer(mover)
    layer?.addSublayer(leading)
    layer?.addSublayer(trailing)
  }

  required init?(coder: NSCoder) { fatalError() }

  override func hitTest(_ point: NSPoint) -> NSView? { nil }

  func set(_ string: String, font: NSFont, color: NSColor, background: (Double, Double, Double)) {
    let next = NSAttributedString(string: string, attributes: [.font: font, .foregroundColor: color])
    let backgroundChanged = background != self.background
    self.background = background
    if backgroundChanged { paintFades() }
    guard next != attributed else { return }
    attributed = next
    natural = ceil(next.size().width)
    setAccessibilityLabel(string)
    needsLayout = true
    layoutSubtreeIfNeeded()
  }

  override func viewDidChangeBackingProperties() {
    super.viewDidChangeBackingProperties()
    text.contentsScale = window?.backingScaleFactor ?? 2
  }

  override func layout() {
    super.layout()
    let height = bounds.height
    let lineHeight = ceil(attributed.size().height)
    MediaMotion.setInstantly {
      text.contentsScale = window?.backingScaleFactor ?? 2
      text.string = attributed
      mover.frame = CGRect(x: 0, y: 0, width: 4000, height: height)
      text.frame = CGRect(x: 0, y: ((height - lineHeight) / 2).rounded(), width: natural + 2, height: lineHeight)
      leading.frame = CGRect(x: 0, y: 0, width: Self.fade, height: height)
      trailing.frame = CGRect(x: bounds.width - Self.fade, y: 0, width: Self.fade, height: height)
      for (i, step) in (leading.sublayers ?? []).enumerated() { step.frame = CGRect(x: CGFloat(i) * Self.fade / CGFloat(Self.fadeSteps), y: 0, width: Self.fade / CGFloat(Self.fadeSteps), height: height) }
      for (i, step) in (trailing.sublayers ?? []).enumerated() {
        step.frame = CGRect(x: Self.fade - CGFloat(i + 1) * Self.fade / CGFloat(Self.fadeSteps), y: 0, width: Self.fade / CGFloat(Self.fadeSteps), height: height)
      }
    }
    let box = bounds.width
    let next = box > 0 && natural > box + 0.5 ? Double(natural - box) : 0
    if abs(next - overflow) >= 0.5 || (next == 0) != (overflow == 0) {
      overflow = next
      group?.restart()
    }
  }

  private func paintFades() {
    let (r, g, b) = background
    for side in [leading, trailing] {
      if side.sublayers == nil {
        for _ in 0..<Self.fadeSteps {
          let step = CALayer()
          step.actions = SurfaceLayer.noActions
          side.addSublayer(step)
        }
      }
      for (i, step) in (side.sublayers ?? []).enumerated() {
        step.backgroundColor = NSColor(srgbRed: r / 255, green: g / 255, blue: b / 255, alpha: 1 - (Double(i) + 0.5) / Double(Self.fadeSteps)).cgColor
      }
    }
    needsLayout = true
  }

  func run(_ timing: MarqueeTiming, from start: CFTimeInterval) {
    for l in [mover, leading, trailing] { l.removeAllAnimations() }
    let shift = overflow
    MediaMotion.setInstantly {
      mover.transform = CATransform3DIdentity
      leading.opacity = 0
      trailing.opacity = shift > 0 ? 1 : 0
    }
    guard timing.overflow >= 1, shift > 0 else { return }
    let move = CAKeyframeAnimation(keyPath: "transform.translation.x")
    move.values = [0, 0, -shift, -shift, 0]
    move.keyTimes = timing.keyTimes.map { NSNumber(value: $0) }
    for (l, isLeading) in [(leading, true), (trailing, false)] {
      let keys = timing.edgeKeys(leading: isLeading)
      let fade = CAKeyframeAnimation(keyPath: "opacity")
      fade.values = keys.values
      fade.keyTimes = keys.times.map { NSNumber(value: $0) }
      configure(fade, timing, start)
      l.add(fade, forKey: "marqueeFade")
    }
    configure(move, timing, start)
    mover.add(move, forKey: "marquee")
  }

  private func configure(_ animation: CAKeyframeAnimation, _ timing: MarqueeTiming, _ start: CFTimeInterval) {
    animation.duration = timing.period
    animation.repeatCount = .infinity
    animation.calculationMode = .linear
    animation.beginTime = start
    animation.isRemovedOnCompletion = false
  }

  var presentedShift: Double { -Double((mover.presentation()?.value(forKeyPath: "transform.translation.x") as? NSNumber)?.doubleValue ?? 0) }
}
