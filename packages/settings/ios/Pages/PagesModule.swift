import AppKit
import ExpoModulesCore
import SolaraStore
import SolaraUI
import SwiftUI

public class PagesModule: Module {
  public func definition() -> ModuleDefinition {
    Name("SolaraPages")

    Function("available") { () -> Bool in
      ProcessInfo.processInfo.environment["ARDIA_NATIVE_PAGES"] == "1" && NativeSettingsHandle.active
    }

    AsyncFunction("devPages") { () -> String in
      MainActor.assumeIsolated { NativePageView.devState() }
    }.runOnQueue(.main)

    View(NativePageView.self) {
      Events("onPageEvent")

      Prop("kind") { (view: NativePageView, v: String) in MainActor.assumeIsolated { view.setKind(v) } }
      Prop("state") { (view: NativePageView, v: String) in MainActor.assumeIsolated { view.setState(v) } }

      AsyncFunction("focusSearch") { (view: NativePageView) in MainActor.assumeIsolated { view.focusSearch() } }.runOnQueue(.main)
    }
  }
}

final class NativePageView: ExpoView {
  let onPageEvent = EventDispatcher()
  private var kind = ""
  private var json = ""
  private var host: NSView?
  private let downloads = DownloadsPageModel()

  override var isFlipped: Bool { true }

  static let live = NSHashTable<NativePageView>.weakObjects()

  required init(appContext: AppContext? = nil) {
    super.init(appContext: appContext)
    downloads.onEvent = { [weak self] event in self?.send(event) }
    Self.live.add(self)
    PageProbe.enabled = ProcessInfo.processInfo.environment["ARDIA_BACKGROUND"] == "1"
  }

  static func devState() -> String {
    let pages: [[String: Any]] = live.allObjects.filter { $0.window != nil }.map { view in
      var page: [String: Any] = ["kind": view.kind]
      switch view.kind {
      case "downloads":
        page["query"] = view.downloads.query
        page["shown"] = view.downloads.shown.map(\.id)
      default: break
      }
      page["ax"] = axLines(view.host, depth: 0)
      page["frames"] = view.probeFrames()
      return page
    }
    guard let data = try? JSONSerialization.data(withJSONObject: ["pages": pages]), let text = String(data: data, encoding: .utf8) else { return "{}" }
    return text
  }

  private func probeFrames() -> [[String: Any]] {
    PageProbe.items.values.map { item in
      ["label": item.label, "x": item.frame.minX, "y": item.frame.minY, "width": item.frame.width, "height": item.frame.height]
    }
  }

  private static func axLines(_ element: Any?, depth: Int) -> [String] {
    guard let element = element as? NSAccessibilityElementProtocol & NSObject, depth < 30 else { return [] }
    let role = (element as? NSAccessibilityProtocol)?.accessibilityRole()?.rawValue ?? "?"
    let label = (element as? NSAccessibilityProtocol)?.accessibilityLabel() ?? ""
    var lines = ["\(String(repeating: " ", count: depth))\(role)\(label.isEmpty ? "" : ": \(label)")"]
    for child in (element as? NSAccessibilityProtocol)?.accessibilityChildren() ?? [] { lines += axLines(child, depth: depth + 1) }
    return lines
  }

  func setKind(_ next: String) {
    guard next != kind else { return }
    kind = next
    host?.removeFromSuperview()
    let made: NSView? =
      switch next {
      case "downloads": NSHostingView(rootView: DownloadsPageView(model: downloads))
      default: nil
      }
    guard let made else { return }
    made.frame = bounds
    made.autoresizingMask = [.width, .height]
    addSubview(made)
    host = made
    if !json.isEmpty { apply() }
  }

  func setState(_ next: String) {
    guard next != json else { return }
    json = next
    apply()
  }

  func focusSearch() {
    switch kind {
    case "downloads": downloads.focusRequest += 1
    default: break
    }
  }

  private func apply() {
    switch kind {
    case "downloads": downloads.apply(json: json)
    default: break
    }
  }

  private func send(_ event: DownloadsPageEvent) {
    let (name, id): (String, String?) =
      switch event {
      case .open(let id): ("open", id)
      case .reveal(let id): ("reveal", id)
      case .pause(let id): ("pause", id)
      case .resume(let id): ("resume", id)
      case .cancel(let id): ("cancel", id)
      case .menu(let id): ("menu", id)
      case .remove(let id): ("remove", id)
      case .source(let id): ("source", id)
      case .clearAll: ("clearAll", nil)
      }
    onPageEvent(["kind": name, "id": id ?? NSNull()])
  }
}
