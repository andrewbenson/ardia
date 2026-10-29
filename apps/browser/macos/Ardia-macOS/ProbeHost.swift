#if SOLARA_PROBES
import AppKit
import ArdiaCore
import Foundation
import SolaraProbes
import SolaraStore
import ArdiaShell
import ArdiaSettings

@_cdecl("SolaraProbeHostMarker")
public func SolaraProbeHostMarker() -> Int32 { 1 }

@MainActor
final class ProbeHost {
  private static var active: ProbeHost?
  private let files: ProbeFiles
  private var seen = ProbeSeenIds()
  private var timer: Timer?

  static func start() {
    guard SolaraProbeHostMarker() == 1 else { return }
    let environment = ProcessInfo.processInfo.environment
    guard Bundle.main.bundleIdentifier?.hasSuffix(".dev") == true,
      environment["ARDIA_BACKGROUND"] == "1",
      ArdiaCoreTestHooksAllowed(),
      let path = environment["ARDIA_DATA_DIR"], !path.isEmpty else {
      NSLog("[solara-probe] gate: identity, background, or hooks denied")
      return
    }
    do {
      let files = try ProbeFiles.open(dataPath: path, defaultPath: ArdiaCoreHost.installedDataDirectory, homePath: NSHomeDirectory())
      files.clearStale()
      let host = ProbeHost(files: files)
      active = host
      host.timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak host] _ in
        MainActor.assumeIsolated { host?.poll() }
      }
    } catch {
      NSLog("[solara-probe] gate: %@", String(describing: error))
    }
  }

  private init(files: ProbeFiles) { self.files = files }

  private func poll() {
    guard Bundle.main.bundleIdentifier?.hasSuffix(".dev") == true,
      ProcessInfo.processInfo.environment["ARDIA_BACKGROUND"] == "1",
      ArdiaCoreTestHooksAllowed(), (try? files.recheck()) != nil else { return }
    for (id, data, readError) in files.claim() {
      let response: [String: Any]
      do {
        guard Bundle.main.bundleIdentifier?.hasSuffix(".dev") == true,
          ProcessInfo.processInfo.environment["ARDIA_BACKGROUND"] == "1",
          ArdiaCoreTestHooksAllowed() else { throw ProbeFailure.testHooksDenied }
        try files.recheck()
        if let readError { throw readError }
        guard let data else { throw ProbeFailure.invalidEnvelope }
        let request = try ProbeRequest.decode(data, nowMs: Int64(Date().timeIntervalSince1970 * 1000))
        guard request.id.caseInsensitiveCompare(id) == .orderedSame else { throw ProbeFailure.invalidEnvelope }
        guard seen.insert(id.lowercased()) else { throw ProbeFailure.duplicate }
        switch request.command {
        case "probe.hello":
          guard request.args.isEmpty else { throw ProbeFailure.invalidArgument }
          response = ["id": id, "protocol": 1, "result": ["protocol": 1, "capabilities": ["probe.hello", "state.snapshot"], "pid": getpid()]]
        case "state.snapshot":
          response = try snapshot(request)
        default:
          throw ProbeFailure.unsupported
        }
      } catch {
        let code = (error as? ProbeFailure)?.code ?? ProbeFailure.invalidEnvelope.code
        response = ["id": id, "protocol": 1, "error": ["code": code]]
      }
      let encoded = try? JSONSerialization.data(withJSONObject: response)
      let output = encoded.flatMap { $0.count <= 65_536 ? $0 : try? JSONSerialization.data(withJSONObject:
        ["id": id, "protocol": 1, "error": ["code": ProbeFailure.oversized.code]]) }
      if let output {
        do { try files.reply(id: id, data: output) }
        catch { NSLog("[solara-probe] reply: %@", String(describing: error)) }
      }
    }
  }

  private func snapshot(_ request: ProbeRequest) throws -> [String: Any] {
    guard Set(request.args.keys).isSubset(of: ["windowId"]),
      request.args["windowId"] == nil || request.args["windowId"] is String else { throw ProbeFailure.invalidArgument }
    guard let store = NativeStoreHandle.store else { throw ProbeFailure.notReady }
    let wanted = request.args["windowId"] as? String
    if let wanted, store.state.windows[wanted] == nil { throw ProbeFailure.windowGone }
    var initial = store.snapshot
    var final = initial
    for attempt in 0..<2 {
      let state = initial.state
      let ids = wanted.map { [$0] } ?? state.windowOrder
      let windows: [[String: Any]] = ids.compactMap { id in
        guard let model = state.windows[id] else { return nil }
        let window = WindowHost.window(id: id)
        let chrome = ArdiaCoreHost.chromeWindows.first { entry in
          if let number = entry["window"] as? Int, number == window?.windowNumber { return true }
          guard entry["hasRoot"] as? Bool == true, let text = entry["frame"] as? String else { return false }
          let frame = NSRectFromString(text)
          if let window { return abs(frame.minX - window.frame.minX) < 2 && abs(frame.width - window.frame.width) < 2 }
          guard let saved = model.frame, saved.count == 4 else { return false }
          return abs(frame.minX - CGFloat(saved[0])) < 2 && abs(frame.width - CGFloat(saved[2])) < 2
        }
        let chromeNumber = chrome?["window"] as? Int
        let chromeWindow = chromeNumber.flatMap { NSApp.window(withWindowNumber: $0) }
        let frame = (chromeWindow ?? window).map { NSRect(origin: .zero, size: $0.frame.size) }
        let selections: [[String: Any]] = model.tabIds.compactMap { tabId in
          guard let selection = PaneOverlayRead.selection(windowId: id, tabId: tabId) else { return nil }
          return ["id": "selection.\(tabId)", "kind": "selection", "tabId": tabId,
            "visible": !(selection["hidden"] as? Bool ?? true),
            "opacity": selection["opacity"] ?? NSNull(),
            "frame": Self.rect(selection["bar"]),
            "controls": [["id": "search", "frame": Self.rect(selection["button"])]],
            "area": Self.rect(selection["area"]), "above": selection["above"] ?? NSNull()]
        }
        return ["id": id, "kind": model.fields.kind ?? "browser", "profileId": model.profileId,
          "incognito": model.incognito, "order": state.windowOrder.firstIndex(of: id) ?? 0,
          "key": window?.isKeyWindow ?? false, "visible": window?.isVisible ?? false,
          "occluded": NSNull(), "frame": Self.value(frame.map(Self.rectFromWindow)),
          "contentFrame": Self.value(window?.contentView.map { Self.rectFromWindow($0.bounds) }),
          "chromeWindowNumber": Self.value(chromeNumber),
          "selectedTabId": Self.value(model.activeTabIds[model.profileId]),
          "selectedTabIds": NSNull(), "activeTabIds": NSNull(), "tabIds": model.tabIds,
          "spaces": NSNull(), "panes": NSNull(), "focus": NSNull(), "overlays": selections,
          "views": NSNull()]
      }
      let allowedIds = Set(ids)
      let tabs: [[String: Any]] = state.tabs.keys.sorted().compactMap { id in
        guard let tab = state.tabs[id], allowedIds.contains(tab.windowId) else { return nil }
        return ["id": id, "windowId": tab.windowId, "profileId": tab.profileId,
          "url": safeURL(tab.url), "title": String(tab.title.prefix(512)),
          "pinned": NSNull(), "loading": NSNull(), "live": Self.value(TabPoolRead.live(id)),
          "visible": NSNull(), "zoom": NSNull()]
      }
      final = store.snapshot
      if final.rev == initial.rev || attempt == 1 {
        return ["id": request.id, "protocol": 1, "result": ["schema": 1,
          "storeRevision": initial.rev, "endRevision": final.rev, "capturedAtNs": DispatchTime.now().uptimeNanoseconds,
          "consistent": final.rev == initial.rev,
          "coordinateSpace": ["origin": "windowContentTopLeft", "unit": "point", "displayScale": windowScale(ids)],
          "focusedWindowId": Self.value(state.ui.focusedWindowId),
          "windows": windows, "tabs": tabs, "profiles": NSNull(),
          "capabilities": ["available": ["windows.frame", "windows.chromeWindowNumber", "tabs.url", "tabs.title", "windows.overlays.selection"],
            "partial": ["tabs.live"], "unavailable": ["windows.occluded", "windows.selectedTabIds", "windows.spaces", "windows.panes", "windows.focus", "windows.views", "tabs.pinned", "tabs.loading", "tabs.visible", "tabs.zoom", "profiles"]]]]
      }
      initial = final
    }
    throw ProbeFailure.timeout
  }

  private func safeURL(_ raw: String) -> Any {
    guard var components = URLComponents(string: raw), let scheme = components.scheme?.lowercased() else { return NSNull() }
    guard ["http", "https", "about", "chrome", "file", "ardia", "solara"].contains(scheme) else { return "\(scheme):" }
    if scheme == "file" {
      let path = components.url.flatMap { ProbeFiles.realPath($0.path) } ?? ""
      guard path == files.dataPath || path.hasPrefix(files.dataPath + "/") else { return NSNull() }
    }
    components.user = nil
    components.password = nil
    return String((components.string ?? raw).prefix(2048))
  }

  private static func value(_ optional: Any?) -> Any { optional ?? NSNull() }

  private static func rect(_ value: Any?) -> Any {
    guard let list = value as? [Double], list.count == 4 else { return NSNull() }
    return ["x": list[0], "y": list[1], "width": list[2], "height": list[3]]
  }

  private static func rectFromWindow(_ value: NSRect) -> [String: Double] {
    ["x": value.minX, "y": value.minY, "width": value.width, "height": value.height]
  }

  private func windowScale(_ ids: [String]) -> Double {
    Double(ids.compactMap { WindowHost.window(id: $0)?.backingScaleFactor }.first ?? 1)
  }
}
#endif
