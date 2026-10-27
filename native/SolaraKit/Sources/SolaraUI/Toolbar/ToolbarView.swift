import AppKit
import QuartzCore

@MainActor
public final class ToolbarView: NSView {
  static let buttonTop: CGFloat = 21.2 - 15
  static let bandEase = CAMediaTimingFunction(controlPoints: 0.25, 0.46, 0.45, 0.94)

  public var onClick: (ToolbarClick) -> Void = { _ in }
  public private(set) var state: ToolbarState?

  private let band = CALayer()
  private let stripes = CALayer()
  private var stripesUri: String?
  private let content = ToolbarContentView()
  private let hairline = CALayer()
  private let progress = CALayer()
  private var left: [ToolbarButtonView] = []
  private var right: [ToolbarButtonView] = []
  private let url = ToolbarUrlFieldView()
  private var bandColor: CGColor?
  private var shownProgress: Double?

  public override var isFlipped: Bool { true }

  public override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
    layer?.addSublayer(band)
    stripes.anchorPoint = .zero
    stripes.contentsGravity = .topLeft
    layer?.addSublayer(stripes)
    addSubview(content)
    content.addSubview(url)
    url.onClick = { [weak self] click in self?.onClick(click) }
    layer?.addSublayer(hairline)
    progress.anchorPoint = .zero
    layer?.addSublayer(progress)
  }

  required init?(coder: NSCoder) { fatalError() }

  public override func hitTest(_ point: NSPoint) -> NSView? {
    let hit = super.hitTest(point)
    return hit === self || hit === content ? nil : hit
  }

  public func update(_ next: ToolbarState) {
    let previous = state
    state = next
    left = sync(left, next.left, next.palette)
    right = sync(right, next.right, next.palette)
    if let u = next.url {
      url.isHidden = false
      url.update(u, palette: next.palette)
    } else {
      url.isHidden = true
    }
    applyBand(next.bare ? nil : toolbarColor(next.palette.background)?.cgColor, animated: previous != nil)
    applyStripes(next.bare ? nil : next.stripes)
    if previous?.focused != next.focused {
      let to: CGFloat = next.focused ? 1 : 0.5
      if previous == nil {
        content.alphaValue = to
      } else {
        NSAnimationContext.runAnimationGroup { ctx in
          ctx.duration = 0.16
          ctx.timingFunction = ToolbarView.bandEase
          content.animator().alphaValue = to
        }
      }
    }
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    hairline.isHidden = !next.hairline
    hairline.backgroundColor = toolbarColor(next.palette.divider)?.cgColor
    CATransaction.commit()
    applyProgress(next.progress, color: toolbarColor(next.palette.background != nil ? next.palette.icon : next.accent))
    needsLayout = true
  }

  private func sync(_ views: [ToolbarButtonView], _ specs: [ToolbarButtonState], _ palette: ToolbarPaletteState) -> [ToolbarButtonView] {
    var out: [ToolbarButtonView] = []
    for (i, spec) in specs.enumerated() {
      if i < views.count, views[i].state.id == spec.id {
        views[i].state = spec
        views[i].palette = palette
        out.append(views[i])
      } else {
        let made = ToolbarButtonView(state: spec, palette: palette)
        made.onClick = { [weak self] click in self?.onClick(click) }
        content.addSubview(made)
        out.append(made)
      }
    }
    for v in views where !out.contains(where: { $0 === v }) { v.removeFromSuperview() }
    return out
  }

  private func applyBand(_ color: CGColor?, animated: Bool) {
    guard color != bandColor else { return }
    let from = bandColor ?? color?.copy(alpha: 0)
    let to = color ?? bandColor?.copy(alpha: 0)
    bandColor = color
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    band.backgroundColor = to
    CATransaction.commit()
    guard animated, let from, let to else { return }
    let animation = CABasicAnimation(keyPath: "backgroundColor")
    animation.fromValue = from
    animation.toValue = to
    animation.duration = 0.18
    animation.timingFunction = ToolbarView.bandEase
    band.add(animation, forKey: "backgroundColor")
  }

  private func applyStripes(_ uri: String?) {
    guard uri != stripesUri else { return }
    stripesUri = uri
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    if let uri, let image = ToolbarView.stripesImage(uri) {
      stripes.contents = image
      stripes.contentsScale = window?.backingScaleFactor ?? 2
      stripes.isHidden = false
    } else {
      stripes.contents = nil
      stripes.isHidden = true
    }
    CATransaction.commit()
  }

  static func stripesImage(_ uri: String) -> NSImage? {
    let url = uri.hasPrefix("/") ? URL(fileURLWithPath: uri) : URL(string: uri)
    guard let url, let data = try? Data(contentsOf: url), let image = NSImage(data: data) else { return nil }
    image.size = NSSize(width: 2560, height: 50)
    return image
  }

  public var urlEditView: NSView? { url.editorView }

  private func applyProgress(_ value: Double?, color: NSColor?) {
    guard let value else {
      progress.isHidden = true
      shownProgress = nil
      return
    }
    let to = max(value, 0.08)
    let width = bounds.width * to
    progress.isHidden = false
    progress.backgroundColor = color?.cgColor
    progress.opacity = 0.85
    let fromWidth = shownProgress.map { bounds.width * max($0, 0.08) } ?? width
    shownProgress = value
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    progress.bounds = CGRect(x: 0, y: 0, width: width, height: 1.5)
    CATransaction.commit()
    guard fromWidth != width else { return }
    let animation = CABasicAnimation(keyPath: "bounds.size.width")
    animation.fromValue = fromWidth
    animation.toValue = width
    animation.duration = 0.2
    animation.timingFunction = ToolbarView.bandEase
    progress.add(animation, forKey: "width")
  }

  public override func layout() {
    super.layout()
    guard let state else { return }
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    band.frame = bounds
    stripes.frame = CGRect(x: 0, y: 0, width: 2560, height: 50)
    layer?.masksToBounds = true
    let scale = window?.backingScaleFactor ?? 2
    hairline.frame = CGRect(x: 0, y: bounds.height - 1 / scale, width: bounds.width, height: 1 / scale)
    progress.position = CGPoint(x: 0, y: bounds.height - 1.5)
    if let shownProgress { progress.bounds.size.width = bounds.width * max(shownProgress, 0.08) }
    CATransaction.commit()
    content.frame = bounds
    let px = { (v: CGFloat) in (v * scale).rounded() / scale }
    let top = px(ToolbarView.buttonTop)
    let g = state.geometry
    let centers = [g.sidebarButton, g.back, g.forward, g.reload]
    let ids = ["sidebar", "back", "forward", "reload"]
    for b in left {
      let center = ids.firstIndex(of: b.state.id).flatMap { centers[$0] } ?? nil
      guard let center else { continue }
      b.frame = CGRect(x: px(CGFloat(center) - 15), y: top, width: 30, height: 30)
    }
    var x = bounds.width - CGFloat(state.rightInset)
    for b in right.reversed() {
      x -= b.box
      b.frame = CGRect(x: px(x), y: top, width: b.box, height: b.box)
      x += 2
    }
    url.frame = CGRect(x: CGFloat(g.urlLeft), y: ToolbarView.buttonTop, width: max(0, bounds.width - CGFloat(g.urlLeft) - CGFloat(g.urlRight)), height: ToolbarUrlFieldView.height)
  }
}

final class ToolbarContentView: NSView {
  override var isFlipped: Bool { true }
}
