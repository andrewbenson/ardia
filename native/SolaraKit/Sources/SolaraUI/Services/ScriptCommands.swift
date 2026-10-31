import Foundation
import SolaraModel
import SolaraOmnibox
import SolaraStore

@MainActor
public protocol WorkspaceWriter: AnyObject {
  var state: BrowserState { get }
  func createWindow(url: String?, incognito: Bool?, profileId: String?) -> String?
  func newTab(_ windowId: String, url: String?, index: Int?) -> String?
  func navigate(_ tabId: String, _ url: String)
  func closeTab(_ tabId: String)
  func closeWindow(_ windowId: String)
  func activate(_ tabId: String)
  func focusWindow(_ windowId: String)
  func activateIndex(_ windowId: String, _ index: Int)
  func switchProfile(_ windowId: String, _ profileId: String)
}

@MainActor
public protocol ScriptPages: AnyObject {
  func has(_ tabId: String) -> Bool
  func call(_ tabId: String, _ method: String, _ args: [Any], done: @escaping (Any?, String?) -> Void)
}

@MainActor
public final class PoolScriptPages<Page>: ScriptPages {
  private let page: (String) -> Page?
  private let invoke: (Page, String, [Any], @escaping (Any?, String?) -> Void) -> Void

  public init(page: @escaping (String) -> Page?, invoke: @escaping (Page, String, [Any], @escaping (Any?, String?) -> Void) -> Void) {
    self.page = page
    self.invoke = invoke
  }

  public func has(_ tabId: String) -> Bool { page(tabId) != nil }

  public func call(_ tabId: String, _ method: String, _ args: [Any], done: @escaping (Any?, String?) -> Void) {
    guard let page = page(tabId) else { return done(nil, ScriptCommandRunner.notLoaded) }
    invoke(page, method, args, done)
  }
}

public enum ScriptReply {
  case result([String: Any])
  case failure(String)
}

@MainActor
public struct ScriptCommandRunner {
  public static let notLoaded = "The tab hasn't loaded yet; focus it first."
  public static let refused: [String: Any] = ["refused": "javaScriptFromAppleEvents"]

  let writer: WorkspaceWriter
  let pages: ScriptPages

  public init(writer: WorkspaceWriter, pages: ScriptPages) {
    self.writer = writer
    self.pages = pages
  }

  public static func runsJavaScript(_ input: String, settings: Settings) -> Bool {
    let resolved = resolveInput(fromLegacyUrl(input.jsTrim()), search: searchUrlPrefix(settings))
    return [input, resolved].contains { asChromiumSeesIt($0).range(of: "^javascript:", options: [.regularExpression, .caseInsensitive]) != nil }
  }

  static func asChromiumSeesIt(_ url: String) -> String {
    var scalars = Substring.UnicodeScalarView(url.unicodeScalars)
    while let first = scalars.first, first.value <= 0x20 { scalars.removeFirst() }
    return String(String.UnicodeScalarView(scalars.filter { $0 != "\t" && $0 != "\n" && $0 != "\r" }))
  }

  public func run(_ request: [String: Any], done: @escaping (ScriptReply) -> Void) -> Bool {
    let s = writer.state
    let allowed = s.settings.bool("allowJavaScriptFromAppleEvents")
    let url = request["url"] as? String
    let refuses = { (url: String?) in url.map { !$0.isEmpty && !allowed && Self.runsJavaScript($0, settings: s.settings) } ?? false }
    let tabId = request["tabId"] as? String ?? ""
    let windowId = request["windowId"] as? String
    let tabGone = "That tab no longer exists."
    let windowGone = "That window no longer exists."
    func reply(_ result: [String: Any] = [:]) -> Bool {
      done(.result(result))
      return true
    }
    func fail(_ message: String) -> Bool {
      done(.failure(message))
      return true
    }
    switch request["command"] as? String {
    case "newWindow":
      if refuses(url) { return reply(Self.refused) }
      let created = writer.createWindow(url: url, incognito: request["incognito"] as? Bool, profileId: request["profileId"] as? String)
      return reply(["windowId": created as Any])
    case "newTab":
      if refuses(url) { return reply(Self.refused) }
      guard let target = s.resolveWindowId(windowId) else {
        let created = writer.createWindow(url: url, incognito: nil, profileId: nil)
        return reply(["windowId": created as Any, "tabId": created.flatMap { writer.state.activeTabId($0) } as Any])
      }
      var index: Int?
      if let wanted = (request["index"] as? NSNumber)?.intValue, let window = s.windows[target] {
        let view = s.viewTabIds(target)
        let pinned = view.filter { s.tabs[$0]?.pinned == true }.count
        let at = max(wanted, pinned)
        index = at < view.count ? window.tabIds.firstIndex(of: view[at]) ?? window.tabIds.count : window.tabIds.count
      }
      return reply(["windowId": target, "tabId": writer.newTab(target, url: url, index: index) as Any])
    case "setURL":
      guard s.tabs[tabId] != nil else { return fail(tabGone) }
      if refuses(url) { return reply(Self.refused) }
      writer.navigate(tabId, url ?? "")
      return reply()
    case "closeTab":
      guard s.tabs[tabId] != nil else { return fail(tabGone) }
      writer.closeTab(tabId)
      return reply()
    case "closeWindow":
      guard let windowId, s.windows[windowId] != nil else { return fail(windowGone) }
      writer.closeWindow(windowId)
      return reply()
    case "reload", "back", "forward":
      guard s.tabs[tabId] != nil else { return fail(tabGone) }
      guard pages.has(tabId) else { return fail(Self.notLoaded) }
      let method = ["reload": "reload", "back": "goBack", "forward": "goForward"][request["command"] as! String]!
      pages.call(tabId, method, []) { _, error in done(error.map(ScriptReply.failure) ?? .result([:])) }
      return true
    case "focusTab":
      guard let tab = s.tabs[tabId] else { return fail(tabGone) }
      writer.activate(tabId)
      if tab.windowId != writer.state.ui.focusedWindowId { writer.focusWindow(tab.windowId) }
      return reply()
    case "setActiveTabIndex":
      guard let windowId, s.windows[windowId] != nil else { return fail(windowGone) }
      let index = (request["index"] as? NSNumber)?.intValue ?? 0
      guard index >= 1, index <= s.viewTabIds(windowId).count else { return fail("There's no tab at that index.") }
      writer.activateIndex(windowId, index - 1)
      return reply()
    case "focusProfile":
      let target = s.resolveWindowId(nil)
      guard let profileId = request["profileId"] as? String, s.profiles[profileId] != nil else { return fail("That profile no longer exists.") }
      guard let target, s.windows[target]?.incognito != true else { return fail("There's no window to show the profile in.") }
      writer.switchProfile(target, profileId)
      return reply()
    case "execute":
      guard s.tabs[tabId] != nil else { return fail(tabGone) }
      if !allowed { return reply(Self.refused) }
      guard pages.has(tabId) else { return fail(Self.notLoaded) }
      pages.call(tabId, "evaluate", [Self.executeWrapper(request["code"] as? String ?? "")]) { value, error in
        if let error { return done(.failure(error)) }
        let outcome = (value as? String).flatMap { $0.data(using: .utf8) }.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
        guard let outcome else { return done(.failure("The page didn't answer.")) }
        if let message = outcome["error"] as? String, !message.isEmpty { return done(.failure(message)) }
        done(.result(["value": outcome["value"] as? String ?? ""]))
      }
      return true
    default:
      return false
    }
  }

  public static func executeWrapper(_ code: String) -> String {
    let literal = String(data: try! JSONSerialization.data(withJSONObject: code, options: [.fragmentsAllowed, .withoutEscapingSlashes]), encoding: .utf8)!
    return """

      const text = (v) => {
        if (v === undefined || v === null) return "";
        if (typeof v === "string") return v;
        try { const json = JSON.stringify(v); return json === undefined ? String(v) : json; } catch { return String(v); }
      };
      let value;
      try { value = (0, eval)(\(literal)); } catch (e) { post("result", JSON.stringify({ error: String(e) })); return; }
      Promise.resolve(value).then(
        (v) => post("result", JSON.stringify({ value: text(v) })),
        (e) => post("result", JSON.stringify({ error: String(e) })),
      );
      """
  }
}

@MainActor
public final class StoreWorkspaceWriter: WorkspaceWriter {
  let store: Store
  let showWindow: (String) -> Void

  public init(store: Store, showWindow: @escaping (String) -> Void) {
    self.store = store
    self.showWindow = showWindow
  }

  public var state: BrowserState { store.state }

  @discardableResult
  private func run(_ name: String, _ args: [JSONValue]) -> JSONValue? {
    (try? store.dispatch(Command(name, args), origin: .native))?.result
  }

  public func createWindow(url: String?, incognito: Bool?, profileId: String?) -> String? {
    var options: JSONObject = [:]
    if let url { options["url"] = .string(url) }
    if let incognito { options["incognito"] = .bool(incognito) }
    if let profileId { options["profileId"] = .string(profileId) }
    return run("createWindow", [.object(options)])?.string
  }

  public func newTab(_ windowId: String, url: String?, index: Int?) -> String? {
    var options: JSONObject = [:]
    if let url { options["url"] = .string(url) }
    if let index { options["index"] = .number(Double(index)) }
    return run("newTab", [.string(windowId), .object(options)])?.string
  }

  public func navigate(_ tabId: String, _ url: String) { run("navigate", [.string(tabId), .string(url)]) }
  public func closeTab(_ tabId: String) { run("closeTab", [.string(tabId)]) }
  public func closeWindow(_ windowId: String) { run("closeWindow", [.string(windowId)]) }
  public func activate(_ tabId: String) { run("activate", [.string(tabId)]) }
  public func activateIndex(_ windowId: String, _ index: Int) { run("activateIndex", [.string(windowId), .number(Double(index))]) }
  public func switchProfile(_ windowId: String, _ profileId: String) { run("switchProfile", [.string(windowId), .string(profileId)]) }

  public func focusWindow(_ windowId: String) {
    run("setFocusedWindow", [.string(windowId)])
    showWindow(windowId)
  }
}
