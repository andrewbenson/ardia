import AppKit
import ExpoModulesCore
import Foundation
import SolaraUI

public class PromptModule: Module {
  public func definition() -> ModuleDefinition {
    Name("SolaraPrompt")

    View(NativePromptView.self) {
      Events("onPromptEvent", "onPromptHeight")

      Prop("state") { (view: NativePromptView, v: String) in MainActor.assumeIsolated { view.setState(v) } }
    }
  }
}

final class NativePromptView: ExpoView {
  let onPromptEvent = EventDispatcher()
  let onPromptHeight = EventDispatcher()
  let body = PromptBodyView(frame: .zero)
  private var json = ""

  override var isFlipped: Bool { true }

  required init(appContext: AppContext? = nil) {
    super.init(appContext: appContext)
    body.autoresizingMask = [.width, .height]
    body.frame = bounds
    body.onHeight = { [weak self] h in self?.onPromptHeight(["height": h]) }
    body.onEvent = { [weak self] e in
      switch e {
      case .button(let id): self?.onPromptEvent(["kind": "button", "id": id])
      case .choice(let id): self?.onPromptEvent(["kind": "choice", "id": id])
      case .toggle(let on): self?.onPromptEvent(["kind": "toggle", "value": on])
      case .close: self?.onPromptEvent(["kind": "close"])
      }
    }
    addSubview(body)
  }

  func setState(_ next: String) {
    guard next != json, let state = PromptState.decode(next) else { return }
    json = next
    body.update(state)
  }
}

public class DeviceChooserModule: Module {
  public func definition() -> ModuleDefinition {
    Name("SolaraDeviceChooser")

    View(NativeDeviceChooserView.self) {
      Events("onChooserEvent", "onChooserHeight")

      Prop("state") { (view: NativeDeviceChooserView, v: String) in MainActor.assumeIsolated { view.setState(v) } }
    }
  }
}

final class NativeDeviceChooserView: ExpoView {
  let onChooserEvent = EventDispatcher()
  let onChooserHeight = EventDispatcher()
  let body = DeviceChooserView(frame: .zero)
  private var json = ""

  override var isFlipped: Bool { true }

  required init(appContext: AppContext? = nil) {
    super.init(appContext: appContext)
    body.autoresizingMask = [.width, .height]
    body.frame = bounds
    body.onHeight = { [weak self] h in self?.onChooserHeight(["height": h]) }
    body.onEvent = { [weak self] e in
      switch e {
      case .select(let i): self?.onChooserEvent(["kind": "select", "index": i])
      case .choose(let i): self?.onChooserEvent(["kind": "choose", "index": i ?? -1])
      case .cancel: self?.onChooserEvent(["kind": "cancel"])
      case .refresh: self?.onChooserEvent(["kind": "refresh"])
      case .openSettings: self?.onChooserEvent(["kind": "openSettings"])
      }
    }
    addSubview(body)
  }

  func setState(_ next: String) {
    guard next != json, let state = DeviceChooserState.decode(next) else { return }
    json = next
    body.update(state)
  }
}

public class PanelModule: Module {
  public func definition() -> ModuleDefinition {
    Name("SolaraPanel")

    View(NativePanelView.self) {
      Events("onPanelEvent", "onPanelHeight")

      Prop("kind") { (view: NativePanelView, v: String) in MainActor.assumeIsolated { view.kind = v } }
      Prop("state") { (view: NativePanelView, v: String) in MainActor.assumeIsolated { view.setState(v) } }
    }
  }
}

final class NativePanelView: ExpoView {
  let onPanelEvent = EventDispatcher()
  let onPanelHeight = EventDispatcher()
  var kind = "" { didSet { if kind != oldValue { apply() } } }
  private var json = ""
  private var applied = ""
  private var zoom: ZoomPanelView?

  override var isFlipped: Bool { true }

  func setState(_ next: String) {
    json = next
    apply()
  }

  private func apply() {
    let key = kind + "\u{1}" + json
    guard !kind.isEmpty, key != applied, let data = json.data(using: .utf8) else { return }
    applied = key
    switch kind {
    case "zoom":
      guard let state = try? JSONDecoder().decode(ZoomPanelState.self, from: data) else { return }
      let body = zoom ?? make { ZoomPanelView(frame: .zero) }
      zoom = body
      body.onEvent = { [weak self] e in
        switch e {
        case .step(let step): self?.onPanelEvent(["kind": "step", "step": step])
        }
      }
      body.update(state)
    default:
      break
    }
  }

  private func make<Body: NSView>(_ build: () -> Body) -> Body {
    let body = build()
    body.autoresizingMask = [.width, .height]
    body.frame = bounds
    if let zoom = body as? ZoomPanelView { zoom.onHeight = { [weak self] h in self?.onPanelHeight(["height": h]) } }
    addSubview(body)
    return body
  }
}
