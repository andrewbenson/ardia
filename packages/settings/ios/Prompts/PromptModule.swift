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
  private var history: HistoryPanelView?
  private var install: ExtensionInstallView?
  private var pins: ExtensionPinsView?
  private var markUri: String?
  private var popover: PopoverView?

  override var isFlipped: Bool { true }

  override func hitTest(_ point: NSPoint) -> NSView? {
    let hit = super.hitTest(point)
    return hit === self ? nil : hit
  }

  private var bodyHeight: CGFloat = 0

  private func reportHeight(_ h: CGFloat) {
    bodyHeight = h
    if popover != nil {
      DispatchQueue.main.async { [weak self] in self?.popover?.set(bodyHeight: h) }
    } else {
      onPanelHeight(["height": h])
    }
  }

  func setState(_ next: String) {
    json = next
    apply()
  }

  private func apply() {
    let key = kind + "\u{1}" + json
    guard !kind.isEmpty, key != applied, let data = json.data(using: .utf8) else { return }
    applied = key
    defer { placePopover(data) }
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
    case "history":
      guard let state = try? JSONDecoder().decode(HistoryPanelState.self, from: data) else { return }
      let body = history ?? make { HistoryPanelView(frame: .zero) }
      if history == nil {
        body.favicons.loader = { request in try await NativeSidebar.favicon(request) }
        body.onHeight = { [weak self] h in self?.reportHeight(h) }
      }
      history = body
      body.onEvent = { [weak self] e in
        switch e {
        case .open(let index, let click):
          self?.onPanelEvent(["kind": "open", "index": index, "metaKey": click.meta, "shiftKey": click.shift, "altKey": click.alt, "middle": click.middle])
        case .fullHistory: self?.onPanelEvent(["kind": "fullHistory"])
        }
      }
      loadMark((try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["newTabMark"] as? String, into: body)
      body.update(state)
    case "extensionInstall":
      guard let state = try? JSONDecoder().decode(ExtensionInstallState.self, from: data) else { return }
      let body = install ?? dialog { ExtensionInstallView(frame: .zero) }
      install = body
      body.update(state)
    case "extensionPins":
      guard let state = try? JSONDecoder().decode(ExtensionPinsState.self, from: data) else { return }
      let body = pins ?? dialog { ExtensionPinsView(frame: .zero) }
      pins = body
      body.update(state)
    default:
      break
    }
  }

  private func dialog<Body: ExtensionDialogBody>(_ build: () -> Body) -> Body {
    let body = make(build)
    body.onHeight = { [weak self] h in self?.reportHeight(h) }
    body.onEvent = { [weak self] e in
      switch e {
      case .cancel: self?.onPanelEvent(["kind": "cancel"])
      case .confirm: self?.onPanelEvent(["kind": "confirm"])
      case .done: self?.onPanelEvent(["kind": "done"])
      case .toggle(let id, let pinned): self?.onPanelEvent(["kind": "toggle", "id": id, "pinned": pinned])
      }
    }
    return body
  }

  private func loadMark(_ uri: String?, into body: HistoryPanelView) {
    guard let uri, uri != markUri else { return }
    markUri = uri
    HistoryPanelMark.load(uri, into: body)
  }

  private func make<Body: NSView>(_ build: () -> Body) -> Body {
    let body = build()
    if let zoom = body as? ZoomPanelView { zoom.onHeight = { [weak self] h in self?.reportHeight(h) } }
    if let data = json.data(using: .utf8), PanelPopover.placement(data) != nil {
      let made = PopoverView(body: body)
      made.autoresizingMask = [.width, .height]
      made.frame = bounds
      made.onDismiss = { [weak self] in self?.onPanelEvent(["kind": "dismiss"]) }
      addSubview(made)
      popover = made
    } else {
      body.autoresizingMask = [.width, .height]
      body.frame = bounds
      addSubview(body)
    }
    return body
  }

  private func placePopover(_ data: Data) {
    guard let popover, let placement = PanelPopover.placement(data) else { return }
    popover.set(placement: placement, dark: PanelPopover.dark(data))
    if bodyHeight > 0 { popover.set(bodyHeight: bodyHeight) }
  }
}

@MainActor
enum HistoryPanelMark {
  static func load(_ uri: String, into body: HistoryPanelView) {
    if let image = SettingsAdapters.image(uri) {
      image.isTemplate = true
      body.favicons.newTabMark = image
      return body.rebuildIcons()
    }
    guard let url = URL(string: uri) else { return }
    Task { @MainActor [weak body] in
      let image = await Task.detached { (try? Data(contentsOf: url)).flatMap(NSImage.init(data:)) }.value
      guard let body, let image else { return }
      image.isTemplate = true
      body.favicons.newTabMark = image
      body.rebuildIcons()
    }
  }
}

enum PanelPopover {
  private struct Envelope: Decodable {
    let popover: PopoverPlacement?
    let dark: Bool?
  }

  static func placement(_ data: Data) -> PopoverPlacement? { (try? JSONDecoder().decode(Envelope.self, from: data))?.popover }

  static func dark(_ data: Data) -> Bool { (try? JSONDecoder().decode(Envelope.self, from: data))?.dark ?? false }
}
