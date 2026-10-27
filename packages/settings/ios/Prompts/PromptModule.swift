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
