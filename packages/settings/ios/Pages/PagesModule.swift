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

    AsyncFunction("devPageHover") { (key: String?) in
      MainActor.assumeIsolated { NativePageView.devHover(key) }
    }.runOnQueue(.main)

    View(NativePageView.self) {
      Events("onPageEvent")

      Prop("kind") { (view: NativePageView, v: String) in MainActor.assumeIsolated { view.setKind(v) } }
      Prop("state") { (view: NativePageView, v: String) in MainActor.assumeIsolated { view.setState(v) } }

      AsyncFunction("focusSearch") { (view: NativePageView) in MainActor.assumeIsolated { view.focusSearch() } }.runOnQueue(.main)
    }
  }
}

@MainActor
enum PageNetwork {
  static let favicons = PageFavicons(
    load: { url, favicon, profile, dark in
      if let favicon, favicon.hasPrefix("data:") || favicon.hasPrefix("file:") || favicon.hasPrefix("/"), let image = SettingsAdapters.image(favicon) { return image }
      guard let uri = await SettingsAdapters.js("newTab.favicon", url, profile, dark) as? String else { return nil }
      if let image = SettingsAdapters.image(uri) { return image }
      guard let source = URL(string: uri), source.isFileURL, let data = try? Data(contentsOf: source) else { return nil }
      return NSImage(data: data)
    },
    bundled: { name in NativeSettingsWindow.bundledSiteIcon(name) })
}

final class NativePageView: ExpoView {
  let onPageEvent = EventDispatcher()
  private var kind = ""
  private var json = ""
  private var host: NSView?
  private let downloads = DownloadsPageModel()
  private let history = HistoryPageModel()
  private let bookmarks = BookmarksPageModel()

  override var isFlipped: Bool { true }

  static let live = NSHashTable<NativePageView>.weakObjects()

  required init(appContext: AppContext? = nil) {
    super.init(appContext: appContext)
    downloads.onEvent = { [weak self] event in self?.send(event) }
    history.onEvent = { [weak self] event in self?.send(event) }
    bookmarks.onEvent = { [weak self] event in self?.send(event) }
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
      case "history":
        page["query"] = view.history.query
        page["shown"] = view.history.shown
        page["selected"] = view.history.selected.sorted()
        page["clearOpen"] = view.history.clearOpen
      case "bookmarks":
        page["query"] = view.bookmarks.query
        page["shown"] = view.bookmarks.ids
        page["selected"] = view.bookmarks.selected
        page["folder"] = view.bookmarks.folderId ?? NSNull()
        page["undo"] = view.bookmarks.undoCount ?? NSNull()
      default: break
      }
      page["ax"] = axLines(view.host, depth: 0)
      page["frames"] = view.probeFrames()
      return page
    }
    guard let data = try? JSONSerialization.data(withJSONObject: ["pages": pages]), let text = String(data: data, encoding: .utf8) else { return "{}" }
    return text
  }

  static func devHover(_ key: String?) {
    for view in live.allObjects where view.window != nil {
      view.history.devHover = key
      view.bookmarks.devHover = key
    }
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
      case "history": NSHostingView(rootView: HistoryPageView(model: history, favicons: PageNetwork.favicons))
      case "bookmarks": NSHostingView(rootView: BookmarksPageView(model: bookmarks, favicons: PageNetwork.favicons))
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
    case "history": history.focusRequest += 1
    case "bookmarks": bookmarks.focusRequest += 1
    default: break
    }
  }

  private func apply() {
    switch kind {
    case "downloads": downloads.apply(json: json)
    case "history": history.apply(json: json)
    case "bookmarks": bookmarks.apply(json: json)
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

  private func send(_ event: HistoryPageEvent) {
    switch event {
    case .open(let url, let mode): onPageEvent(["kind": "open", "url": url, "mode": mode.rawValue])
    case .remove(let urls): onPageEvent(["kind": "remove", "urls": urls])
    case .deleteSelected(let urls): onPageEvent(["kind": "deleteSelected", "urls": urls])
    case .clearData(let request): onPageEvent(["kind": "clearData", "range": request.range, "history": request.history, "siteData": request.siteData])
    }
  }

  private func send(_ event: BookmarksPageEvent) {
    switch event {
    case .open(let url, let mode): onPageEvent(["kind": "open", "url": url, "mode": mode.rawValue])
    case .openAll(let id, let newWindow): onPageEvent(["kind": "openAll", "id": id, "newWindow": newWindow])
    case .edit(let id): onPageEvent(["kind": "edit", "id": id])
    case .addGroup(let id): onPageEvent(["kind": "addGroup", "id": id])
    case .restoreArc(let id): onPageEvent(["kind": "restoreArc", "id": id])
    case .delete(let ids): onPageEvent(["kind": "delete", "ids": ids])
    case .undo: onPageEvent(["kind": "undo"])
    case .move(let ids, let drop, let listed):
      switch drop {
      case .into(let folder): onPageEvent(["kind": "move", "ids": ids, "into": folder, "listed": listed])
      case .at(let parentId, let index): onPageEvent(["kind": "move", "ids": ids, "parentId": parentId, "index": index, "listed": listed])
      }
    case .addBookmark(let parent): onPageEvent(["kind": "addBookmark", "parentId": parent ?? NSNull()])
    case .addFolder(let parent): onPageEvent(["kind": "addFolder", "parentId": parent ?? NSNull()])
    case .importBookmarks: onPageEvent(["kind": "import"])
    }
  }
}
