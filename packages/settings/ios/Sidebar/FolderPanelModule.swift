import AppKit
import ExpoModulesCore
import Foundation
import SolaraUI

public class FolderPanelModule: Module {
  public func definition() -> ModuleDefinition {
    Name("SolaraFolderPanel")

    Events("onFolderPanelEvent")

    Function("available") { () -> Bool in NativeSidebar.enabled }

    AsyncFunction("show") { (windowId: String, json: String) in
      let sink = FolderPanelSink(self)
      MainActor.assumeIsolated {
        guard let page = NativeSidebar.hosts[windowId]?.view.current, let data = json.data(using: .utf8),
          let request = try? JSONDecoder().decode(FolderPanelRequest.self, from: data)
        else { return }
        SidebarFolderPanelHost.show(on: page, windowId: windowId, request: request) { event in
          sink.module?.send(windowId: windowId, folderId: request.folderId, event)
        }
      }
    }.runOnQueue(.main)

    AsyncFunction("hide") { (windowId: String) in
      MainActor.assumeIsolated {
        guard let page = NativeSidebar.hosts[windowId]?.view.current else { return }
        SidebarFolderPanelHost.hide(on: page)
      }
    }.runOnQueue(.main)
  }

  fileprivate func send(windowId: String, folderId: String, _ event: FolderPanelEvent) {
    var body: [String: Any] = ["windowId": windowId, "folderId": folderId]
    switch event {
    case .open(let tabId):
      body["kind"] = "open"
      body["tabId"] = tabId
    case .tabMenu(let tabId):
      body["kind"] = "tabMenu"
      body["tabId"] = tabId
    case .folderMenu: body["kind"] = "folderMenu"
    case .outsidePress: body["kind"] = "outsidePress"
    case .drag: return
    }
    sendEvent("onFolderPanelEvent", body)
  }
}

private final class FolderPanelSink: @unchecked Sendable {
  weak var module: FolderPanelModule?
  init(_ module: FolderPanelModule) { self.module = module }
}
