import AppKit
import ExpoModulesCore
import Foundation
import SolaraStore
import SolaraUI

public class ToolbarModule: Module {
  public func definition() -> ModuleDefinition {
    Name("SolaraToolbar")

    Function("available") { () -> Bool in
      ProcessInfo.processInfo.environment["ARDIA_NATIVE_OMNIBOX"] == "1" && NativeSettingsHandle.active
    }

    View(NativeToolbarHostView.self) {
      Events("onToolbarClick", "onToolbarAnchors")

      Prop("state") { (view: NativeToolbarHostView, v: String) in MainActor.assumeIsolated { view.setState(v) } }
    }
  }
}

final class NativeToolbarHostView: ExpoView {
  let onToolbarClick = EventDispatcher()
  let onToolbarAnchors = EventDispatcher()
  let toolbar = ToolbarView(frame: .zero)
  private var json = ""

  override var isFlipped: Bool { true }

  required init(appContext: AppContext? = nil) {
    super.init(appContext: appContext)
    toolbar.autoresizingMask = [.width, .height]
    toolbar.frame = bounds
    toolbar.onClick = { [weak self] click in
      self?.onToolbarClick(["id": click.id, "kind": click.kind.rawValue, "meta": click.meta, "alt": click.alt, "shift": click.shift, "text": click.text ?? NSNull()])
    }
    toolbar.onAnchors = { [weak self] anchors in
      self?.onToolbarAnchors(["anchors": anchors.mapValues { [$0.minX, $0.minY, $0.width, $0.height] }])
    }
    addSubview(toolbar)
  }

  override func setFrameOrigin(_ newOrigin: NSPoint) {
    super.setFrameOrigin(newOrigin)
    toolbar.needsLayout = true
  }

  override func hitTest(_ point: NSPoint) -> NSView? {
    let hit = super.hitTest(point)
    return hit === self ? nil : hit
  }

  func setState(_ next: String) {
    guard next != json, let state = ToolbarState.decode(next) else { return }
    json = next
    toolbar.update(state)
  }
}
