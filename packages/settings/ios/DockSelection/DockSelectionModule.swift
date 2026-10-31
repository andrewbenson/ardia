import AppKit
import ExpoModulesCore
import SolaraUI

public class DockSelectionModule: Module {
  public func definition() -> ModuleDefinition {
    Name("SolaraDockSelection")

    AsyncFunction("iconTheme") { (uri: String?, emoji: String?) -> [String: String]? in
      guard let source = IconRingSource(uri: uri, emoji: emoji) else { return nil }
      return MainActor.assumeIsolated { IconRingView.theme(of: source)?.json }
    }.runOnQueue(.main)

    View(DockSelection.self) {
      Prop("image") { (view: DockSelection, v: String?) in view.uri = v }
      Prop("emoji") { (view: DockSelection, v: String?) in view.emoji = v }
      Prop("theme") { (view: DockSelection, v: String?) in view.kind = v ?? "" }
      Prop("fill") { (view: DockSelection, hex: String?) in view.fill = hex.flatMap { CSSColor($0)?.ns } }
      Prop("stroke") { (view: DockSelection, hex: String?) in view.stroke = hex.flatMap { CSSColor($0)?.ns } }
      Prop("cornerRadius") { (view: DockSelection, v: Double) in view.ring.cornerRadius = v }
      Prop("strokeWidth") { (view: DockSelection, v: Double) in view.ring.strokeWidth = v }
      Prop("dark") { (view: DockSelection, v: Bool) in view.ring.dark = v }
      Prop("iconSize") { (view: DockSelection, v: Double) in view.ring.iconSize = v }
      Prop("glass") { (view: DockSelection, v: Bool?) in view.ring.glass = v ?? false }
    }
  }
}

final class DockSelection: ExpoView {
  let ring = IconRingView()
  var uri: String? { didSet { if uri != oldValue { sync() } } }
  var emoji: String? { didSet { if emoji != oldValue { sync() } } }
  var kind = "" { didSet { if kind != oldValue { sync() } } }
  var fill: NSColor? { didSet { if fill != oldValue { sync() } } }
  var stroke: NSColor? { didSet { if stroke != oldValue { sync() } } }

  required init(appContext: AppContext? = nil) {
    super.init(appContext: appContext)
    wantsLayer = true
    ring.autoresizingMask = [.width, .height]
    ring.frame = bounds
    addSubview(ring)
  }

  override func hitTest(_ point: NSPoint) -> NSView? { nil }

  private func sync() {
    ring.source = IconRingSource(uri: uri, emoji: emoji)
    switch kind {
    case "blur": ring.theme = .blur
    case "template": ring.theme = .template(fill: (fill ?? .clear).cgColor, stroke: stroke?.cgColor)
    default: ring.theme = nil
    }
  }
}
