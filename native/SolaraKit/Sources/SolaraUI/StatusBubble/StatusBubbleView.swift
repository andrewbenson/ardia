import AppKit
import SwiftUI

public struct StatusBubbleOverlay: View {
  let model: StatusBubbleModel

  public init(model: StatusBubbleModel) {
    self.model = model
  }

  public var body: some View {
    GeometryReader { geometry in
      if !model.text.isEmpty {
        StatusBubbleView(text: model.text, expanded: model.expanded, containerWidth: geometry.size.width)
          .opacity(model.opaque ? 1 : 0)
          .animation(.linear(duration: StatusBubbleTiming.fade), value: model.opaque)
          .padding(StatusBubbleMetrics.inset)
          .frame(width: geometry.size.width, height: geometry.size.height, alignment: model.pinnedTrailing ? .bottomTrailing : .bottomLeading)
      }
    }
    .allowsHitTesting(false)
    .accessibilityHidden(true)
  }
}

public struct StatusBubbleView: View {
  let text: String
  let expanded: Bool
  let containerWidth: CGFloat

  public init(text: String, expanded: Bool, containerWidth: CGFloat) {
    self.text = text
    self.expanded = expanded
    self.containerWidth = containerWidth
  }

  public static var font: NSFont { .systemFont(ofSize: StatusBubbleMetrics.fontSize, weight: .medium) }

  public static func width(of text: String, containerWidth: CGFloat, expanded: Bool) -> CGFloat {
    let measured = NSAttributedString(string: text, attributes: [.font: font]).size().width
    return StatusBubbleMetrics.width(text: measured, containerWidth: containerWidth, expanded: expanded)
  }

  public var body: some View {
    Text(verbatim: text)
      .font(.system(size: StatusBubbleMetrics.fontSize, weight: .medium))
      .foregroundStyle(Color(nsColor: .secondaryLabelColor))
      .lineLimit(1)
      .truncationMode(expanded ? .tail : .middle)
      .padding(.horizontal, StatusBubbleMetrics.padding)
      .frame(width: Self.width(of: text, containerWidth: containerWidth, expanded: expanded), height: StatusBubbleMetrics.height)
      .background(StatusBubbleChrome().padding(-StatusBubbleChromeView.shadowRoom))
  }
}

struct StatusBubbleChrome: NSViewRepresentable {
  func makeNSView(context: Context) -> StatusBubbleChromeView { StatusBubbleChromeView() }

  func updateNSView(_ view: StatusBubbleChromeView, context: Context) {}
}

final class StatusBubbleChromeView: NSView {
  static let border = NSColor(name: "StatusBubbleBorder") { appearance in
    appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
      ? NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.2) : NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.1)
  }

  static let shadowRoom = StatusBubbleMetrics.shadowRadius * 3

  let shadowLayer = CALayer()
  let pill = NSView()
  let effect = NSVisualEffectView()
  private var maskedSize: CGSize = .zero

  override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
    layer?.masksToBounds = false
    pill.wantsLayer = true
    pill.layer?.masksToBounds = false
    pill.layer?.borderWidth = StatusBubbleMetrics.borderWidth
    shadowLayer.shadowColor = CGColor(gray: 0, alpha: 1)
    shadowLayer.shadowOpacity = StatusBubbleMetrics.shadowOpacity
    shadowLayer.shadowRadius = StatusBubbleMetrics.shadowRadius
    shadowLayer.shadowOffset = .zero
    shadowLayer.zPosition = -1
    layer?.addSublayer(shadowLayer)
    effect.material = .popover
    effect.blendingMode = .withinWindow
    effect.wantsLayer = true
    pill.addSubview(effect)
    addSubview(pill)
    applyAppearance()
  }

  required init?(coder: NSCoder) { fatalError() }

  override func hitTest(_ point: NSPoint) -> NSView? { nil }

  override func layout() {
    super.layout()
    pill.frame = bounds.insetBy(dx: Self.shadowRoom, dy: Self.shadowRoom)
    effect.frame = pill.bounds
    let size = pill.bounds.size
    let radius = size.height / 2
    pill.layer?.cornerRadius = radius
    effect.layer?.cornerRadius = radius
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    shadowLayer.frame = pill.frame
    shadowLayer.shadowPath = CGPath(roundedRect: pill.bounds, cornerWidth: radius, cornerHeight: radius, transform: nil)
    CATransaction.commit()
    if maskedSize != size {
      maskedSize = size
      effect.maskImage = Self.capsule(radius: radius)
    }
  }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    applyAppearance()
  }

  private func applyAppearance() {
    effectiveAppearance.performAsCurrentDrawingAppearance {
      pill.layer?.borderColor = Self.border.cgColor
    }
  }

  static func capsule(radius: CGFloat) -> NSImage {
    let side = radius * 2 + 1
    let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
      NSColor.black.setFill()
      NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
      return true
    }
    image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
    image.resizingMode = .stretch
    return image
  }
}

@MainActor
public final class StatusBubbleHost: NSView {
  public let model: StatusBubbleModel
  private let hosting: NSHostingView<StatusBubbleOverlay>
  private var monitor: Any?

  public init(model: StatusBubbleModel = StatusBubbleModel()) {
    self.model = model
    hosting = PassThroughHostingView(rootView: StatusBubbleOverlay(model: model))
    super.init(frame: .zero)
    hosting.sizingOptions = []
    hosting.safeAreaRegions = []
    hosting.frame = bounds
    hosting.autoresizingMask = [.width, .height]
    addSubview(hosting)
  }

  required init?(coder: NSCoder) { fatalError() }

  public override var isFlipped: Bool { true }

  public override var acceptsFirstResponder: Bool { false }

  public override func hitTest(_ point: NSPoint) -> NSView? { nil }

  public func setDark(_ dark: Bool?) {
    let next = dark.map { NSAppearance(named: $0 ? .darkAqua : .aqua) } ?? nil
    if appearance?.name != next?.name { appearance = next }
  }

  public var bubbleFrame: CGRect {
    let width = StatusBubbleView.width(of: model.text, containerWidth: bounds.width, expanded: model.expanded)
    let x = model.pinnedTrailing ? bounds.width - StatusBubbleMetrics.inset - width : StatusBubbleMetrics.inset
    return CGRect(x: x, y: bounds.height - StatusBubbleMetrics.inset - StatusBubbleMetrics.height, width: width, height: StatusBubbleMetrics.height)
  }

  public func pointerMoved(toWindowPoint point: NSPoint) {
    guard model.mounted else { return }
    model.pointerMoved(convert(point, from: nil), bubble: bubbleFrame, containerWidth: bounds.width)
  }

  public override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    if let monitor { NSEvent.removeMonitor(monitor) }
    monitor = nil
    guard window != nil else { return model.reset() }
    monitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] event in
      if let self, event.window === self.window { self.pointerMoved(toWindowPoint: event.locationInWindow) }
      return event
    }
  }
}

private final class PassThroughHostingView: NSHostingView<StatusBubbleOverlay> {
  override func hitTest(_ point: NSPoint) -> NSView? { nil }

  override var acceptsFirstResponder: Bool { false }
}
