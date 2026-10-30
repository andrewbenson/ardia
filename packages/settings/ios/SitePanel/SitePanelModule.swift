import AppKit
import ExpoModulesCore
import Foundation
import SolaraModel
import SolaraUI

public class SitePanelModule: Module {
  public func definition() -> ModuleDefinition {
    Name("SolaraSitePanel")

    View(NativeSitePanelView.self) {
      Events("onSitePanelEvent", "onSitePanelDismiss", "onSitePanelClosed")

      Prop("request") { (view: NativeSitePanelView, v: String) in MainActor.assumeIsolated { view.setRequest(v) } }
    }
  }
}

final class NativeSitePanelView: ExpoView {
  let onSitePanelEvent = EventDispatcher()
  let onSitePanelDismiss = EventDispatcher()
  let onSitePanelClosed = EventDispatcher()
  private var siteMenu: NativeSiteMenu?

  override var isFlipped: Bool { true }

  required init(appContext: AppContext? = nil) {
    super.init(appContext: appContext)
  }

  func setRequest(_ json: String) {
    guard let data = json.data(using: .utf8), let request = try? JSONValue.parse(data) else { return }
    if request["open"]?.bool != true {
      siteMenu?.close()
      return
    }
    if let siteMenu, !siteMenu.popover.isClosing {
      siteMenu.update(request)
      return
    }
    siteMenu?.popover.removeFromSuperview()
    let next = NativeSiteMenu(input: request)
    siteMenu = next
    next.onDismiss = { [weak self] in self?.onSitePanelDismiss([:]) }
    next.onClosed = { [weak self, weak next] in
      guard let self, let next, self.siteMenu === next else { return }
      next.popover.removeFromSuperview()
      self.siteMenu = nil
      self.onSitePanelClosed([:])
    }
    next.onContribution = { [weak self] event in self?.contribution(event) }
    next.popover.frame = bounds
    addSubview(next.popover)
    next.refresh()
  }

  private func contribution(_ event: SitePanelEvent) {
    func rect(_ r: CGRect) -> [Double] { [r.minX, r.minY, r.width, r.height] }
    let clickAt = NSApp.currentEvent.map { $0.type == .leftMouseUp ? $0.timestamp * 1000 : 0 } ?? 0
    switch event {
    case .press(let id, let r): onSitePanelEvent(["kind": "press", "id": id, "rect": rect(r), "clickAt": clickAt])
    case .menu(let id, let r): onSitePanelEvent(["kind": "menu", "id": id, "rect": rect(r)])
    case .toggle(let id, let value): onSitePanelEvent(["kind": "toggle", "id": id, "value": value])
    case .zoom(let id, let step): onSitePanelEvent(["kind": "zoom", "id": id, "step": step])
    }
  }

  override func hitTest(_ point: NSPoint) -> NSView? { siteMenu?.popover.hitTest(point) }

  override func viewWillMove(toWindow newWindow: NSWindow?) {
    super.viewWillMove(toWindow: newWindow)
    if newWindow == nil { siteMenu?.close() }
  }
}
