import AppKit
import ExpoModulesCore
import Foundation
import SolaraUI

public class DownloadsModule: Module {
  public func definition() -> ModuleDefinition {
    Name("SolaraDownloads")

    View(NativeDownloadsView.self) {
      Events("onDownloadsEvent", "onDownloadsHeight")

      Prop("state") { (view: NativeDownloadsView, v: String) in MainActor.assumeIsolated { view.setState(v) } }
    }
  }
}

final class NativeDownloadsView: ExpoView {
  let onDownloadsEvent = EventDispatcher()
  let onDownloadsHeight = EventDispatcher()
  let list = DownloadsListView(frame: .zero)
  private var json = ""

  override var isFlipped: Bool { true }

  required init(appContext: AppContext? = nil) {
    super.init(appContext: appContext)
    list.autoresizingMask = [.width, .height]
    list.frame = bounds
    list.onHeight = { [weak self] h in self?.onDownloadsHeight(["height": h]) }
    list.onEvent = { [weak self] e in
      let (kind, id): (String, String?) =
        switch e {
        case .open(let id): ("open", id)
        case .reveal(let id): ("reveal", id)
        case .pause(let id): ("pause", id)
        case .resume(let id): ("resume", id)
        case .cancel(let id): ("cancel", id)
        case .menu(let id): ("menu", id)
        case .clear: ("clear", nil)
        case .viewAll: ("viewAll", nil)
        }
      self?.onDownloadsEvent(["kind": kind, "id": id ?? NSNull()])
    }
    addSubview(list)
  }

  func setState(_ next: String) {
    guard next != json, let state = DownloadsListState.decode(next) else { return }
    json = next
    list.update(state)
  }
}
