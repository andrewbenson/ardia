import AppKit
import ExpoModulesCore
import Foundation
import SolaraUI

public class SitePanelModule: Module {
  public func definition() -> ModuleDefinition {
    Name("SolaraSitePanel")

    View(NativeSitePanelView.self) {
      Events("onSitePanelEvent", "onSitePanelHeight")

      Prop("state") { (view: NativeSitePanelView, v: String) in MainActor.assumeIsolated { view.setState(v) } }
    }
  }
}

final class NativeSitePanelView: ExpoView {
  let onSitePanelEvent = EventDispatcher()
  let onSitePanelHeight = EventDispatcher()
  let body = SitePanelView(frame: .zero)
  private var json = ""

  override var isFlipped: Bool { true }

  required init(appContext: AppContext? = nil) {
    super.init(appContext: appContext)
    body.autoresizingMask = [.width, .height]
    body.frame = bounds
    body.favicons = NewTabNetwork.favicons
    body.onHeight = { [weak self] h in self?.onSitePanelHeight(["height": h]) }
    body.onEvent = { [weak self] e in
      func rect(_ r: CGRect) -> [Double] { [r.minX, r.minY, r.width, r.height] }
      let clickAt = NSApp.currentEvent.map { $0.type == .leftMouseUp ? $0.timestamp * 1000 : 0 } ?? 0
      switch e {
      case .press(let id, let r): self?.onSitePanelEvent(["kind": "press", "id": id, "rect": rect(r), "clickAt": clickAt])
      case .menu(let id, let r): self?.onSitePanelEvent(["kind": "menu", "id": id, "rect": rect(r)])
      case .toggle(let id, let on): self?.onSitePanelEvent(["kind": "toggle", "id": id, "value": on])
      case .zoom(let id, let step): self?.onSitePanelEvent(["kind": "zoom", "id": id, "step": step])
      }
    }
    addSubview(body)
  }

  func setState(_ next: String) {
    guard next != json, let state = SitePanelState.decode(next) else { return }
    json = next
    body.update(state)
  }
}
