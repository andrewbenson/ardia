import AppKit
import QuartzCore

public enum TabCapture: String, Decodable, Equatable, Sendable {
  case screen
  case camera
}

public final class TabMediaBadgesView: NSView {
  private let pip = CALayer()
  private let pipGlyph = SymbolView()
  private let capture = CALayer()
  private let captureGlyph = SymbolView()
  private var shown: (pip: Bool, capture: TabCapture?, size: CGFloat, badge: NSColor, glyph: NSColor)?

  public override var isFlipped: Bool { true }

  public override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
    layer?.masksToBounds = false
    for l in [pip, capture] {
      l.actions = SurfaceLayer.noActions
      layer?.addSublayer(l)
    }
    addSubview(pipGlyph)
    addSubview(captureGlyph)
  }

  required init?(coder: NSCoder) { fatalError() }

  public override func hitTest(_ point: NSPoint) -> NSView? { nil }

  public var isEmpty: Bool { shown.map { !$0.pip && $0.capture == nil } ?? true }

  public func set(pip showsPip: Bool, capture kind: TabCapture?, iconSize size: CGFloat, badge: NSColor, badgeGlyph: NSColor) {
    shown = (showsPip, kind, size, badge, badgeGlyph)
    let box = bounds.size
    MediaMotion.setInstantly {
      pip.isHidden = !showsPip
      if showsPip {
        let d = (size * 0.72).rounded()
        pip.frame = CGRect(x: box.width - d + d / 3, y: -d / 3, width: d, height: d)
        pip.cornerRadius = d / 2
        pip.backgroundColor = badge.cgColor
      }
      capture.isHidden = kind == nil
      capture.borderWidth = 0
      if kind == .screen {
        let d = (size * 0.72).rounded()
        capture.frame = CGRect(x: box.width - d + d / 3, y: box.height - d + d / 3, width: d, height: d)
        capture.cornerRadius = d / 2
      } else if kind == .camera {
        let d = max(6, (size * 0.44).rounded())
        capture.frame = CGRect(x: box.width - d + d / 4, y: box.height - d + d / 4, width: d, height: d)
        capture.cornerRadius = d / 2
        capture.borderWidth = 1
        capture.borderColor = NSColor(white: 0, alpha: 0.25).cgColor
      }
      capture.backgroundColor = MediaTokens.captureRed.cgColor
    }
    pipGlyph.isHidden = !showsPip
    if showsPip {
      pipGlyph.frame = pip.frame
      pipGlyph.set("pip.fill", size: pip.frame.width * 0.55, weight: .bold, color: badgeGlyph)
    }
    captureGlyph.isHidden = kind != .screen
    if kind == .screen {
      captureGlyph.frame = capture.frame
      captureGlyph.set("rectangle.inset.filled", size: capture.frame.width * 0.5, weight: .bold, color: .white)
    }
  }

  public override func setFrameSize(_ newSize: NSSize) {
    super.setFrameSize(newSize)
    if let shown { set(pip: shown.pip, capture: shown.capture, iconSize: shown.size, badge: shown.badge, badgeGlyph: shown.glyph) }
  }
}

extension TabMediaBadgesView {
  @MainActor
  static func attach(_ view: inout TabMediaBadgesView?, to parent: NSView, flags: SidebarFlags, tabId: String?, host: SidebarHostState, palette: SidebarPalette) {
    let pip = tabId.map { flags.pip.contains($0) } ?? false
    let capture = tabId.flatMap { flags.capture[$0] }
    guard pip || capture != nil else {
      view?.isHidden = true
      return
    }
    let badges = view ?? {
      let made = TabMediaBadgesView()
      parent.addSubview(made)
      parent.needsLayout = true
      return made
    }()
    view = badges
    badges.isHidden = false
    let fill = host.badge?.first.flatMap { CSSColor($0)?.ns } ?? palette.textSecondary
    let glyph = host.badge.flatMap { $0.count > 1 ? CSSColor($0[1])?.ns : nil } ?? .white
    badges.set(pip: pip, capture: capture, iconSize: 16, badge: fill, badgeGlyph: glyph)
  }
}
