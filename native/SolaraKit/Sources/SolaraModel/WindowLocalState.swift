public struct WindowUi: JSONConvertible {
  public static let closedPanel: JSONValue = ["open": false, "initialText": ""]

  public var json: JSONObject

  public init() {
    json = ["panel": Self.closedPanel, "downloadsOpen": false]
  }

  public init(json: JSONObject) {
    self.json = json
  }

  public var panelOpen: Bool { json["panel"]?["open"]?.truthy ?? false }
  public var downloadsOpen: Bool { json["downloadsOpen"]?.truthy ?? false }
}

public struct TabSelection: JSONConvertible {
  public var ids: [String]

  public init(_ ids: [String]) {
    self.ids = ids
  }

  public init(json: JSONObject) {
    ids = json["ids"]?.array?.compactMap(\.string) ?? []
  }

  public var json: JSONObject { ["ids": JSONValue(ids)] }
}

public struct SelectionAnchor: JSONConvertible {
  public var tabId: String

  public init(_ tabId: String) {
    self.tabId = tabId
  }

  public init(json: JSONObject) {
    tabId = json["tabId"]?.string ?? ""
  }

  public var json: JSONObject { ["tabId": .string(tabId)] }
}

extension BrowserState {
  public mutating func closePanel(_ windowId: String) {
    guard var entry = windowUi[windowId], entry.json["panel"] != WindowUi.closedPanel else { return }
    entry.json["panel"] = WindowUi.closedPanel
    windowUi[windowId] = entry
  }

  public mutating func openDownloads(_ windowId: String) {
    setDownloadsOpen(windowId, true)
  }

  public mutating func setDownloadsOpen(_ windowId: String, _ open: Bool) {
    guard windows.contains(windowId) else { return }
    var entry = windowUi[windowId] ?? WindowUi()
    guard entry.json["downloadsOpen"] != .bool(open) else { return }
    entry.json["downloadsOpen"] = .bool(open)
    windowUi[windowId] = entry
  }

  public mutating func clearSelection(_ windowId: String) {
    guard selection[windowId] != nil else { return }
    selection[windowId] = nil
  }

  public mutating func swapSelection(_ a: String, _ b: String) {
    for (windowId, picked) in selection where picked.ids.contains(a) || picked.ids.contains(b) {
      selection[windowId] = TabSelection(picked.ids.map { $0 == a ? b : $0 == b ? a : $0 })
    }
  }

  public mutating func pruneWindowLocalState(tabsChanged: Bool, windowsChanged: Bool) {
    if tabsChanged {
      find = find.filter { id, _ in tabs.contains(id) }
      for (windowId, picked) in selection where picked.ids.contains(where: { !tabs.contains($0) }) {
        let kept = picked.ids.filter { tabs.contains($0) }
        selection[windowId] = kept.isEmpty ? nil : TabSelection(kept)
      }
    }
    if windowsChanged {
      selection = selection.filter { id, _ in windows.contains(id) }
      selectionAnchors = selectionAnchors.filter { id, _ in windows.contains(id) }
      windowUi = windowUi.filter { id, _ in windows.contains(id) }
    }
  }
}
