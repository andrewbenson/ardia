import AppKit
import ExpoModulesCore
import Foundation
import SolaraModel
import SolaraStore
import SolaraUI

public class ToolbarModule: Module {
  public func definition() -> ModuleDefinition {
    Name("SolaraToolbar")

    Function("available") { () -> Bool in
      LaunchSwitches.shared.isOn(.nativeOmnibox, defaultOn: true) && NativeSettingsHandle.active
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
  private static let live = NSHashTable<NativeToolbarHostView>.weakObjects()

  static func toolbar(windowId: String, tabId: String) -> ToolbarView? { host(windowId: windowId, tabId: tabId)?.toolbar }

  static func host(windowId: String, tabId: String) -> NativeToolbarHostView? {
    let tabWindow = NativeStoreHandle.store?.state.tabs[tabId]?.windowId
    guard tabWindow == nil || tabWindow == windowId else { return nil }
    let hosts = live.allObjects.filter { $0.window != nil && $0.toolbar.state?.tabId == tabId }
    return hosts.first { !$0.isHiddenOrHasHiddenAncestor } ?? hosts.first
  }

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
    Self.live.add(self)
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
    AutoHideHost.toolbarReady(tabId: state.tabId)
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    if window != nil, let tabId = toolbar.state?.tabId { AutoHideHost.toolbarReady(tabId: tabId) }
  }
}
