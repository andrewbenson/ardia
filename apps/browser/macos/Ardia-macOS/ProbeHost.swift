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
    guard Set(request.args.keys).isSubset(of: ["windowId", "dropTargets", "viewFrames", "hitPoint", "reactBlockerStep"]),
      request.args["windowId"] == nil || request.args["windowId"] is String else { throw ProbeFailure.invalidArgument }
    let dropTargets = request.args["dropTargets"] as? [[String: Any]] ?? []
    let viewFrames = request.args["viewFrames"] as? [String] ?? []
    let hitPoint = request.args["hitPoint"] as? [Double]
    let blockerStep = request.args["reactBlockerStep"] as? Double
    let dropTypes = Set(["public.file-url", "public.url", "public.utf8-plain-text"])
    guard request.args["dropTargets"] == nil || request.args["dropTargets"] is [[String: Any]],
      request.args["viewFrames"] == nil || request.args["viewFrames"] is [String],
      request.args["hitPoint"] == nil || hitPoint?.count == 2,
      request.args["reactBlockerStep"] == nil || (blockerStep != nil && blockerStep! >= 8 && blockerStep! <= 64),
      dropTargets.count <= 12, viewFrames.count <= 4,
      viewFrames.allSatisfy({ ["PopoverView", "SidebarTabCardView", "SplitChromeView"].contains($0) }),
      dropTargets.allSatisfy({ sample in
        sample.count == 3 && (sample["x"] as? Double)?.isFinite == true &&
          (sample["y"] as? Double)?.isFinite == true &&
          (sample["type"] as? String).map(dropTypes.contains) == true
      }) else { throw ProbeFailure.invalidArgument }
    guard let store = NativeStoreHandle.store else { throw ProbeFailure.notReady }
    let wanted = request.args["windowId"] as? String
    if let wanted, wanted != "settings", store.state.windows[wanted] == nil { throw ProbeFailure.windowGone }
    var initial = store.snapshot
    var final = initial
    for attempt in 0..<2 {
      let state = initial.state
      let ids = wanted == "settings" ? [] : wanted.map { [$0] } ?? state.windowOrder
      var windows: [[String: Any]] = ids.compactMap { id in
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
        var overlays = selections
        for tabId in model.tabIds {
          if let zoom = PaneOverlayRead.zoom(windowId: id, tabId: tabId) { overlays.append(Self.popover(zoom, kind: "zoom", tabId: tabId)) }
          if let history = PaneOverlayRead.history(windowId: id, tabId: tabId) { overlays.append(Self.popover(history, kind: "history", tabId: tabId)) }
          if let sadTab = PaneOverlayRead.sadTab(windowId: id, tabId: tabId) { overlays.append(Self.sadTabOverlay(sadTab, tabId: tabId)) }
        }
        if let downloads = DownloadsPanelRead.panel(windowId: id) { overlays.append(Self.downloadsOverlay(downloads)) }
        let focusedURL = OmniboxRead.focusedURL(windowId: id).map { source -> [String: Any] in
          ["field": source["field"] ?? NSNull(), "value": safeURL(source["value"] as? String ?? ""),
            "selection": source["selection"] ?? NSNull()]
        }
        var dropSamples: [[String: Any]] = []
        var frames: [String: Any] = [:]
        if let chromeNumber {
          for sample in dropTargets {
            let x = sample["x"] as! Double
            let y = sample["y"] as! Double
            let type = sample["type"] as! String
            let target = PagesRead.dropTarget(windowNumber: chromeNumber, x: x, y: y, type: type)
            dropSamples.append(["x": x, "y": y, "type": type, "view": target["view"] ?? NSNull(), "chain": target["chain"] ?? []])
          }
          for needle in viewFrames { frames[needle] = PagesRead.viewFrame(windowNumber: chromeNumber, needle: needle) }
        }
        var media: [String: Any] = [:]
        for kind in ["media.sidebarPlayer", "media.hoverPlayer", "media.cliPill", "media.castPicker", "media.sharePicker"] {
          media[kind] = MediaRead.rows(kind: kind, windowId: id)
        }
        let hitSlot = hitPoint.flatMap { WindowShellRead.hitSlot(windowId: id, x: $0[0], y: $0[1]) }
        let hitView = hitPoint.flatMap { WindowShellRead.hitView(windowId: id, x: $0[0], y: $0[1]) }
        let responder = (chromeWindow ?? window)?.firstResponder.map { NSStringFromClass(type(of: $0)) }
        return ["id": id, "kind": model.fields.kind ?? "browser", "profileId": model.profileId,
          "incognito": model.incognito, "order": state.windowOrder.firstIndex(of: id) ?? 0,
          "key": window?.isKeyWindow ?? false, "visible": window?.isVisible ?? false,
          "occluded": NSNull(), "frame": Self.value(frame.map(Self.rectFromWindow)),
          "accessibilityLayers": Self.value(WindowShellRead.accessibilityReach(windowId: id)),
          "split": Self.value(SplitChromeRead.snapshot(windowId: id)),
          "tour": Self.value(ToolTourRead.snapshot(windowId: id)),
          "folderPanel": Self.value(FolderPanelRead.snapshot(windowId: id)),
          "iconPicker": Self.value(SidebarIconPickerRead.snapshot(windowId: id)),
          "shell": Self.value(WindowShellRead.snapshot(windowId: id)),
          "sidebarShell": Self.value(SidebarShellRead.snapshot(windowId: id)),
          "sidebarChromeMetrics": Self.value(SidebarChromeRead.snapshot(windowId: id)),
          "sidebarAddressBar": Self.value(SidebarAddressBarRead.snapshot(windowId: id)),
          "hoverCard": Self.value(SidebarHoverCardRead.snapshot(windowId: id)),
          "reactBlockers": Self.value(blockerStep.flatMap { WindowShellRead.reactBlockers(windowId: id, step: $0) }),
          "dropTargets": dropSamples, "viewFrames": frames, "hitSlot": Self.value(hitSlot), "hitView": Self.value(hitView),
          "firstResponder": Self.value(responder),
          "textFieldCount": Self.value(chromeNumber.flatMap { WindowAccessibilityRead.textFieldCount(windowNumber: $0) }),
          "media": media, "mediaEnabled": MediaRead.enabled, "mediaKinds": MediaRead.kinds,
          "paneOverlays": Self.value(PaneOverlayRead.snapshot(windowId: id)),
          "contentFrame": Self.value(window?.contentView.map { Self.rectFromWindow($0.bounds) }),
          "chromeWindowNumber": Self.value(chromeNumber),
          "selectedTabId": Self.value(model.activeTabIds[model.profileId]),
          "selectedTabIds": NSNull(), "activeTabIds": NSNull(), "tabIds": model.tabIds,
          "spaces": NSNull(), "panes": NSNull(), "focus": NSNull(), "focusedURL": Self.value(focusedURL), "overlays": overlays,
          "views": NSNull()]
      }
      if wanted == nil || wanted == "settings", let settingsWindow = WindowHost.window(id: "settings"),
        let settings = SettingsRead.snapshot() {
        windows.append(["id": "settings", "kind": "settings", "visible": settingsWindow.isVisible,
          "frame": Self.rectFromWindow(NSRect(origin: .zero, size: settingsWindow.frame.size)),
          "overlays": [], "settings": settings])
      }
      let allowedIds = Set(ids)
      let tabs: [[String: Any]] = state.tabs.keys.sorted().compactMap { id in
        guard let tab = state.tabs[id], allowedIds.contains(tab.windowId) else { return nil }
        return ["id": id, "windowId": tab.windowId, "profileId": tab.profileId,
          "url": safeURL(tab.url), "title": String(tab.title.prefix(512)),
          "customTitle": Self.value(tab.customTitle.map { String($0.prefix(512)) }),
          "customIcon": Self.value(tab.customIcon),
          "pinned": NSNull(), "loading": NSNull(), "live": Self.value(TabPoolRead.live(id)),
          "visible": NSNull(), "zoom": tab.zoom]
      }
      let upscaling = VideoUpscalingRead.snapshot()
      let upscalingTabs: [[String: Any]] = (upscaling["tabs"] as? [[String: Any]] ?? []).map { entry in
        ["tabId": entry["tabId"] ?? NSNull(), "url": safeURL(entry["url"] as? String ?? ""),
          "allowed": entry["allowed"] ?? NSNull()]
      }
      let upscalingWindows: [[String: Any]] = (upscaling["windows"] as? [[String: Any]] ?? []).map { entry in
        ["key": entry["key"] ?? NSNull(), "visible": entry["visible"] ?? NSNull(),
          "miniaturized": entry["miniaturized"] ?? NSNull(), "occlusionVisible": entry["occlusionVisible"] ?? NSNull(),
          "littleArdia": entry["littleArdia"] ?? NSNull(), "internal": entry["internal"] ?? NSNull(),
          "focusedTab": safeURL(entry["focusedTab"] as? String ?? "")]
      }
      let videoUpscaling: [String: Any] = ["tabs": upscalingTabs, "windows": upscalingWindows,
        "enabled": upscaling["enabled"] ?? NSNull(), "lowPower": upscaling["lowPower"] ?? NSNull(),
        "thermalPressure": upscaling["thermalPressure"] ?? NSNull(), "appActive": upscaling["appActive"] ?? NSNull()]
      final = store.snapshot
      if final.rev == initial.rev || attempt == 1 {
        return ["id": request.id, "protocol": 1, "result": ["schema": 1,
          "storeRevision": initial.rev, "endRevision": final.rev, "capturedAtNs": DispatchTime.now().uptimeNanoseconds,
          "consistent": final.rev == initial.rev,
          "coordinateSpace": ["origin": "windowContentTopLeft", "unit": "point", "displayScale": windowScale(ids)],
          "focusedWindowId": Self.value(state.ui.focusedWindowId), "poolAvailable": TabPoolRead.available,
          "windowDragCount": WindowDragRead.count, "onboarding": OnboardingRead.snapshot(), "newTabAvailable": NewTabRead.available, "swipeSimulation": SwipeRead.snapshot,
          "videoUpscaling": videoUpscaling,
          "windows": windows, "tabs": tabs, "downloads": ["count": state.downloads.count, "finished": state.downloads.filter { $0.state == "finished" }.count], "profiles": NSNull(),
          "capabilities": ["available": ["windows.frame", "windows.chromeWindowNumber", "windows.accessibilityLayers", "windows.focusedURL", "windows.split", "windows.tour", "windows.folderPanel", "windows.iconPicker", "windows.shell", "windows.sidebarShell", "windows.sidebarChromeMetrics", "windows.sidebarAddressBar", "windows.hoverCard", "windows.reactBlockers", "windows.dropTargets", "windows.viewFrames", "windows.hitSlot", "windows.hitView", "windows.firstResponder", "windows.textFieldCount", "windows.media", "windows.mediaEnabled", "windows.mediaKinds", "windows.paneOverlays", "poolAvailable", "onboarding", "newTabAvailable", "windowDragCount", "swipeSimulation", "videoUpscaling", "tabs.url", "tabs.title", "tabs.customTitle", "tabs.customIcon", "tabs.zoom", "windows.overlays.selection", "windows.overlays.zoom", "windows.overlays.history", "windows.overlays.downloads", "windows.overlays.sadTab", "downloads.count", "downloads.finished", "windows.settings.layout", "windows.settings.search"],
            "partial": ["tabs.live"], "unavailable": ["windows.occluded", "windows.selectedTabIds", "windows.spaces", "windows.panes", "windows.focus", "windows.views", "tabs.pinned", "tabs.loading", "tabs.visible", "profiles"]]]]
      }
      initial = final
    }
    throw ProbeFailure.timeout
  }

  private static func popover(_ source: [String: Any], kind: String, tabId: String) -> [String: Any] {
    let controls = source["controls"] as? [String: [Double]] ?? [:]
    let labels = kind == "zoom" ? ["Zoom In (⌘+)"] : controls.keys.filter { $0 != "Show Full History" }.sorted()
    return ["id": "\(kind).\(tabId)", "kind": kind, "tabId": tabId,
      "visible": !(source["hidden"] as? Bool ?? true), "opacity": source["opacity"] ?? NSNull(),
      "frame": rect(source["card"]), "area": rect(source["frame"]),
      "controls": labels.compactMap { label in controls[label].map { ["id": label, "frame": rect($0)] } }]
  }

  private static func sadTabOverlay(_ source: [String: Any], tabId: String) -> [String: Any] {
    let controls = source["controls"] as? [String: [Double]] ?? [:]
    return ["id": "sadTab.\(tabId)", "kind": "sadTab", "tabId": tabId,
      "visible": !(source["hidden"] as? Bool ?? true), "mode": source["mode"] ?? NSNull(),
      "frame": rect(source["frame"]),
      "controls": controls.keys.sorted().map { ["id": $0, "frame": rect(controls[$0])] }]
  }

  private static func downloadsOverlay(_ source: [String: Any]) -> [String: Any] {
    let controls = source["controls"] as? [String: [Double]] ?? [:]
    return ["id": "downloads", "kind": "downloads", "visible": true,
      "opacity": source["opacity"] ?? NSNull(), "frame": rect(source["card"]),
      "list": rect(source["list"]),
      "controls": controls.keys.sorted().map { ["id": $0, "frame": rect(controls[$0])] }]
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
