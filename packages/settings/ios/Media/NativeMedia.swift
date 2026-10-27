import AppKit
import Foundation
import SolaraUI

@MainActor
enum NativeMedia {
  static let cliPill = "media.cliPill"
  static let sidebarPlayer = "media.sidebarPlayer"
  static let hoverPlayer = "media.hoverPlayer"
  static let shareBar = "media.shareBar"
  static let smallBar = "littleSolara.bar"

  nonisolated static var enabled: Bool {
    ProcessInfo.processInfo.environment["ARDIA_NATIVE_MEDIA"] == "1"
  }

  private static var mounted: [(kind: String, windowId: String, view: WeakMediaView)] = []

  static func register() {
    guard enabled else { return }
    MediaImages.load = { SettingsAdapters.image($0) }
    MediaImages.favicons.loader = { request in
      guard let uri = try await SettingsAdapters.jsThrowing("media.favicon", request.url, request.profileId, request.dark) as? String else { return nil }
      return SettingsAdapters.image(uri)
    }
    HostedViews.register(sidebarPlayer) { windowId in
      let view = SidebarPlayerView()
      var tabId = ""
      view.onAction = { player("sidebarPlayer", windowId, tabId, $0) }
      return content(sidebarPlayer, windowId, view) { json in
        guard let state = MediaPlayerState.decode(json) else { return }
        tabId = state.tabId
        view.update(state)
      }
    }
    HostedViews.register(shareBar) { windowId in
      let view = ShareBarView()
      var target: (capturer: String, tabId: String) = ("", "")
      view.onAction = { action(windowId, "shareBar", target.tabId, ["action": $0.rawValue, "capturer": target.capturer]) }
      return content(shareBar, windowId, view) { json in
        guard let state = ShareBarState.decode(json) else { return }
        target = (state.capturer, state.tabId)
        view.update(state)
      }
    }
    HostedViews.register(smallBar) { windowId in
      let view = SmallBarView()
      var tabId = ""
      view.onAction = { event in
        switch event {
        case .button(let id): action(windowId, "smallBar", tabId, ["action": id])
        case .fieldClick: action(windowId, "smallBar", tabId, ["action": "field"])
        case .fieldMenu: action(windowId, "smallBar", tabId, ["action": "fieldMenu"])
        case .profile: action(windowId, "smallBar", tabId, ["action": "profile"])
        }
      }
      return content(smallBar, windowId, view) { json in
        guard let state = SmallBarState.decode(json) else { return }
        tabId = state.tabId ?? ""
        view.update(state)
      }
    }
    HostedViews.register(hoverPlayer) { windowId in
      let view = MiniPlayerView()
      var tabId = ""
      view.onAction = { player("hoverPlayer", windowId, tabId, $0) }
      return content(hoverPlayer, windowId, view) { json in
        guard let state = MediaPlayerState.decode(json) else { return }
        tabId = state.tabId
        view.update(state)
      }
    }
    HostedViews.register(cliPill) { windowId in
      let view = CliControlPillView()
      view.onStop = { action(windowId, "cliStop") }
      return content(cliPill, windowId, view) { json in
        if let state = CliPillState.decode(json) { view.update(state) }
      }
    }
  }

  private static func content(_ kind: String, _ windowId: String, _ view: NSView, onState: @escaping (String) -> Void) -> HostedContent {
    mounted.removeAll { $0.view.value == nil }
    let entry = WeakMediaView(view)
    mounted.append((kind, windowId, entry))
    return HostedContent(
      view: view, onUnmount: { mounted.removeAll { $0.view === entry } }, takesFocus: false, onState: onState)
  }

  static func player(_ source: String, _ windowId: String, _ tabId: String, _ action: MediaAction) {
    var extra: [String: Any] = ["action": action.name]
    if let seconds = action.seconds { extra["seconds"] = seconds }
    NativeMedia.action(windowId, source, tabId, extra)
  }

  static func action(_ windowId: String, _ name: String, _ tabId: String = "", _ extra: [String: Any] = [:]) {
    let payload = MediaPayload(extra)
    Task { @MainActor in
      _ = await SettingsAdapters.js("media.action", windowId, name, tabId, payload.value)
    }
  }

  static func probe(kind: String, windowId: String) -> String {
    let views = mounted.filter { $0.kind == kind && $0.windowId == windowId }.compactMap { $0.view.value }
    func frames(_ view: NSView, _ controls: [String: CGRect]) -> [String: [Double]] {
      guard let content = view.window?.contentView else { return [:] }
      return controls.mapValues { rect in
        let r = view.convert(rect, to: content)
        return [r.minX, content.bounds.height - r.maxY, r.width, r.height]
      }
    }
    let rows: [[String: Any]] = views.compactMap { view in
      if let mini = view as? MiniPlayerView {
        return [
          "marquee": mini.marqueeProgress, "titleShift": mini.titleShift, "titleOverflow": mini.titleOverflow, "artistOverflow": mini.artistOverflow,
          "hover": mini.hoverProgress ?? NSNull(), "elapsed": mini.elapsedText, "artwork": mini.showsArtwork, "t": CACurrentMediaTime(), "frames": frames(mini, mini.controlFrames),
        ]
      }
      if let bar = view as? SmallBarView {
        return ["progress": Double(bar.progressWidth), "hovered": bar.fieldHovered, "frames": frames(bar, bar.controlFrames)]
      }
      if let bar = view as? ShareBarView {
        return ["primary": bar.primaryTitle, "frames": frames(bar, bar.controlFrames)]
      }
      if let player = view as? SidebarPlayerView {
        return ["corners": player.cornersShown, "seek": player.seekProgress, "height": player.frame.height, "frames": frames(player, player.controlFrames)]
      }
      guard let pill = view as? CliControlPillView, let content = pill.window?.contentView else { return nil }
      let frame = pill.convert(pill.pillFrame, to: content)
      let presented = pill.subviews.first?.layer?.presentation()
      return [
        "shown": pill.shown, "progress": pill.progress, "opacity": Double(presented?.opacity ?? 0), "t": CACurrentMediaTime(),
        "frame": [frame.minX, content.bounds.height - frame.maxY, frame.width, frame.height],
      ]
    }
    let json = try? JSONSerialization.data(withJSONObject: rows)
    return json.flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
  }
}

final class WeakMediaView {
  weak var value: NSView?

  init(_ value: NSView) { self.value = value }
}

struct MediaPayload: @unchecked Sendable {
  let value: [String: Any]

  init(_ value: [String: Any]) { self.value = value }
}
