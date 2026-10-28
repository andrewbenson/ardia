import AppKit

public enum PageEvents {
  public static let props: [String: String] = [
    "navigation": "onNavigationChange",
    "progress": "onProgress",
    "favicon": "onFavicon",
    "media": "onMedia",
    "nowPlaying": "onNowPlaying",
    "mediaAccess": "onMediaAccess",
    "openWindow": "onOpenWindow",
    "popupBlocked": "onPopupBlocked",
    "find": "onFindResult",
    "fullscreen": "onFullscreen",
    "status": "onStatus",
    "crashed": "onCrashed",
    "unresponsive": "onUnresponsive",
    "responsive": "onResponsive",
    "loadError": "onLoadError",
    "security": "onSecurity",
    "zoom": "onZoom",
    "contentBlocked": "onContentBlocked",
    "downloadNavigation": "onDownloadNavigation",
    "notification": "onNotification",
    "notificationClose": "onNotificationClose",
    "pictureInPicture": "onPictureInPicture",
    "activateRequest": "onActivateRequest",
    "displayMediaRequest": "onDisplayMediaRequest",
    "windowClose": "onWindowClose",
    "command": "onCommand",
    "focus": "onPageFocus",
    "pagePress": "onPagePress",
    "pageMessage": "onPageMessage",
    "ready": "onReady",
    "discarded": "onDiscarded",
    "passwordPrompt": "onPasswordPrompt",
    "autofillPrompt": "onAutofillPrompt",
    "tabStrip": "onTabStrip",
    "externalApp": "onExternalApp",
    "preferredSize": "onPreferredSize",
  ]

  public static let names: [String] = props.values.sorted()

  static func dispatchers<Dispatcher>(of view: Any, as _: Dispatcher.Type) -> [String: Dispatcher] {
    var out: [String: Dispatcher] = [:]
    for child in Mirror(reflecting: view).children {
      if let label = child.label, let dispatcher = child.value as? Dispatcher { out[label] = dispatcher }
    }
    return out
  }
}

public enum PageCallError: Error {
  case argument(String, Int)
}

struct PageArgs {
  let method: String
  let values: [Any]

  func optional(_ i: Int) -> Any? {
    guard i < values.count, !(values[i] is NSNull) else { return nil }
    return values[i]
  }

  func string(_ i: Int) -> String? { optional(i) as? String }
  func bool(_ i: Int) -> Bool? { (optional(i) as? NSNumber)?.boolValue }
  func double(_ i: Int) -> Double? { (optional(i) as? NSNumber)?.doubleValue }
  func int(_ i: Int) -> Int? { (optional(i) as? NSNumber)?.intValue }

  func required<T>(_ i: Int, _ read: (Int) -> T?) throws -> T {
    guard let value = read(i) else { throw PageCallError.argument(method, i) }
    return value
  }

  func string(required i: Int) throws -> String { try required(i, string) }
  func bool(required i: Int) throws -> Bool { try required(i, bool) }
  func double(required i: Int) throws -> Double { try required(i, double) }
  func int(required i: Int) throws -> Int { try required(i, int) }
  func strings(required i: Int) throws -> [String] { try required(i) { optional($0) as? [String] } }
}

@MainActor
public enum PageCalls {
  public typealias Resolve = (Any?) -> Void
  public typealias Reject = (_ code: String, _ message: String) -> Void

  public static let methods: Set<String> = [
    "loadUrl", "goBack", "goForward", "goToOffset", "reload", "forceReload", "stopLoading", "focus", "setMuted",
    "zoomStep", "find", "stopFinding", "print", "runPageCommand", "showDevTools", "executeJavaScript", "evaluate",
    "navigationEntries", "capturePicture", "downloadFavicon", "downloadImage", "mediaCommand",
    "requestPictureInPicture", "takeControlPress", "exitPictureInPicture", "getSecurityInfo", "pageCookies",
    "openBlockedPopup", "clearSiteData", "resolvePasswordPrompt", "resolveAutofillPrompt", "executeExtensionAction",
    "resolveDisplayMedia", "mediaCaptureSourceId", "notificationAction", "resolveUnresponsive", "discard", "setFrozen",
  ]

  public static func run(_ page: NSView, _ method: String, _ args: [Any], resolve: @escaping Resolve, reject: @escaping Reject) {
    let a = PageArgs(method: method, values: args)
    guard methods.contains(method) else { return reject("ERR_PAGE_METHOD", "no page method \(method)") }
    do {
      switch page {
      case let web as ArdiaCoreWebView: try engine(web, method, a, resolve)
      case let tab as WebKitTab: try webKit(tab, method, a, resolve)
      default: reject("ERR_NO_PAGE", "no page view for \(method)")
      }
    } catch PageCallError.argument(let name, let index) {
      reject("ERR_PAGE_ARGS", "\(name): argument \(index) is missing or of the wrong type")
    } catch {
      reject("ERR_PAGE_CALL", "\(method): \(error)")
    }
  }

  private static func engine(_ web: ArdiaCoreWebView, _ method: String, _ a: PageArgs, _ resolve: @escaping Resolve) throws {
    switch method {
    case "loadUrl": web.loadURL(try a.string(required: 0), userInitiated: a.bool(1) ?? false)
    case "goBack": web.goBack()
    case "goForward": web.goForward()
    case "goToOffset": web.go(toHistoryOffset: try a.int(required: 0))
    case "reload": web.reload()
    case "forceReload": web.reloadIgnoringCache()
    case "stopLoading": web.stopLoading()
    case "focus": web.focusPage()
    case "setMuted": web.setMuted(try a.bool(required: 0))
    case "zoomStep": web.zoomStep(try a.int(required: 0))
    case "find": web.find(try a.string(required: 0), forward: try a.bool(required: 1), findNext: try a.bool(required: 2))
    case "stopFinding": web.stopFinding(try a.bool(required: 0))
    case "print": web.print()
    case "runPageCommand": web.runPageCommand(try a.string(required: 0))
    case "showDevTools": web.showDevTools(panel: a.string(0))
    case "executeJavaScript": web.executeJavaScript(try a.string(required: 0))
    case "evaluate": return web.evaluate(try a.string(required: 0)) { resolve($0) }
    case "navigationEntries": return web.navigationEntries { resolve($0) }
    case "capturePicture": return web.capturePicture(try a.double(required: 0)) { resolve($0) }
    case "downloadFavicon": return web.downloadFavicon(try a.string(required: 0), name: nil) { resolve($0) }
    case "downloadImage": return web.downloadImage(try a.string(required: 0), maxPixels: try a.int(required: 1)) { resolve($0) }
    case "mediaCommand": web.mediaCommand(try a.string(required: 0), seconds: a.double(1) ?? 0)
    case "requestPictureInPicture":
      return web.requestPictureInPicture(clickAt: a.double(0) ?? 0, control: a.int(1) ?? 0) { resolve($0) }
    case "takeControlPress": return resolve(web.takeControlPress(clickAt: a.double(0) ?? 0, control: a.int(1) ?? 0))
    case "exitPictureInPicture": web.exitPictureInPicture()
    case "getSecurityInfo": return web.securityInfo { resolve($0) }
    case "pageCookies": return web.pageCookies(try a.strings(required: 0)) { resolve($0 ?? []) }
    case "openBlockedPopup": web.openBlockedPopup(try a.string(required: 0), always: a.bool(1) ?? false)
    case "clearSiteData": return web.clearSiteData { resolve($0) }
    case "resolvePasswordPrompt": web.resolvePasswordPrompt(try a.string(required: 0), username: a.string(1), password: a.string(2))
    case "resolveAutofillPrompt": web.resolveAutofillPrompt(try a.int(required: 0), action: try a.string(required: 1))
    case "executeExtensionAction": return resolve(web.executeExtensionAction(try a.string(required: 0)))
    case "resolveDisplayMedia": web.resolveDisplayMedia(try a.string(required: 0), sourceId: a.string(1), audio: try a.bool(required: 2))
    case "mediaCaptureSourceId": return resolve(web.mediaCaptureSourceId)
    case "notificationAction": web.notificationAction(try a.string(required: 0), action: try a.string(required: 1))
    case "resolveUnresponsive": web.resolveUnresponsive(terminate: try a.bool(required: 0))
    case "discard": return resolve(web.discard(unload: a.bool(0) ?? false))
    case "setFrozen": web.frozen = try a.bool(required: 0)
    default: break
    }
    resolve(nil)
  }

  private static func webKit(_ tab: WebKitTab, _ method: String, _ a: PageArgs, _ resolve: @escaping Resolve) throws {
    switch method {
    case "loadUrl": tab.loadURL(try a.string(required: 0), userInitiated: a.bool(1) ?? false)
    case "goBack": tab.goBack()
    case "goForward": tab.goForward()
    case "goToOffset": tab.go(toHistoryOffset: try a.int(required: 0))
    case "reload": tab.reload()
    case "forceReload": tab.reloadIgnoringCache()
    case "stopLoading": tab.stopLoading()
    case "focus": tab.focusPage()
    case "setMuted": tab.setMuted(try a.bool(required: 0))
    case "zoomStep": tab.zoomStep(try a.int(required: 0))
    case "find": tab.find(try a.string(required: 0), forward: try a.bool(required: 1), findNext: try a.bool(required: 2))
    case "stopFinding": tab.stopFinding(try a.bool(required: 0))
    case "print": tab.print()
    case "runPageCommand": tab.runPageCommand(try a.string(required: 0))
    case "executeJavaScript": tab.executeJavaScript(try a.string(required: 0))
    case "evaluate": return tab.evaluate(try a.string(required: 0)) { resolve($0) }
    case "navigationEntries": return resolve(tab.navigationEntries())
    case "capturePicture": return tab.capturePicture(try a.double(required: 0)) { resolve($0) }
    case "downloadFavicon", "downloadImage": return tab.downloadFavicon(try a.string(required: 0)) { resolve($0) }
    case "mediaCommand": tab.mediaCommand(try a.string(required: 0), seconds: a.double(1) ?? 0)
    case "requestPictureInPicture": return tab.setPictureInPicture(true) { resolve($0) }
    case "takeControlPress": return resolve(true)
    case "exitPictureInPicture": tab.setPictureInPicture(false) { _ in }
    case "getSecurityInfo": return resolve(tab.securityInfo())
    case "pageCookies": return resolve([[String: Any]]())
    case "clearSiteData": return tab.clearSiteData { resolve($0) }
    case "discard": return resolve("unsupported")
    default: break
    }
    resolve(nil)
  }
}
