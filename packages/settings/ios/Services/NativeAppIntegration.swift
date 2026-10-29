import AppKit
import ArdiaCore
import ArdiaShell
import Foundation
import SolaraModel
import SolaraStore
import SolaraUI

@MainActor
final class NativeAppIntegration {
  static let shared = NativeAppIntegration()
  static let handoffDelay: TimeInterval = 0.25
  static let firstHandoffDelay: TimeInterval = 1

  nonisolated static let active: Bool = NativeCliControl.enabled && NativeStoreHandle.opened && NativeStoreHandle.ownsWorkspace

  private var handoff = HandoffTracker()
  private var handoffQueued = false
  private var started = false
  private var scriptRev = -1
  private var scriptLoading: Set<String> = []

  private init() {}

  func startWhenReady(tries: Int = 40) {
    guard Self.active, !started else { return }
    guard let store = NativeStoreHandle.store else {
      guard tries > 0 else { return NSLog("[services] the native store never opened, so app services stay in JS") }
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { self.startWhenReady(tries: tries - 1) }
      return
    }
    started = true
    NativeMenuCommands.handlers = [
      "sendFeedback": { windowId in NativeAppIntegration.shared.sendFeedback(windowId) },
      "copyDiagnostics": { _ in NativeAppIntegration.copy(NativeAppIntegration.shared.diagnostics()) },
      "recordPerformanceIssue": { _ in NativeAppIntegration.shared.recordPerformanceIssue() },
      "taskManager": { _ in ArdiaCoreServices.call("ac_task_manager_open", profile: "", args: nil) { _ in } },
    ]
    let writer = StoreWorkspaceWriter(store: store, showWindow: ShellScripting.showWindow)
    let pages = PooledScriptPages()
    ShellScripting.nativeCommand = { body, done in
      MainActor.assumeIsolated {
        ScriptCommandRunner(writer: writer, pages: pages).run(body) { reply in
          switch reply {
          case .result(let result): done(result, nil)
          case .failure(let message): done(nil, message)
          }
        }
      }
    }
    ShellScripting.refresh = { MainActor.assumeIsolated { NativeAppIntegration.shared.refreshScriptState() } }
    store.subscribe { _ in
      DispatchQueue.main.async { MainActor.assumeIsolated { NativeAppIntegration.shared.queueHandoff() } }
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + Self.firstHandoffDelay) { self.syncHandoff() }
  }

  private func queueHandoff() {
    guard !handoffQueued else { return }
    handoffQueued = true
    DispatchQueue.main.asyncAfter(deadline: .now() + Self.handoffDelay) {
      self.handoffQueued = false
      self.syncHandoff()
    }
  }

  private func syncHandoff() {
    guard let state = NativeStoreHandle.store?.state else { return }
    for change in handoff.changes(state) { Handoff.setActivity(windowId: change.windowId, url: change.url, title: change.title) }
  }

  private func refreshScriptState() {
    guard let store = NativeStoreHandle.store else { return }
    let (rev, state) = store.snapshot
    let loading = ShellScripting.loadingTabs
    guard rev != scriptRev || loading != scriptLoading else { return }
    scriptRev = rev
    scriptLoading = loading
    ShellScripting.setState(ScriptState.build(state, loading: loading))
  }

  func diagnostics() -> String {
    let state = NativeStoreHandle.store?.state ?? BrowserState()
    return AppDiagnostics.report(
      app: AppFacts(AppModule.systemInfo), chromiumVersion: ArdiaCoreHost.engineInfo["chromiumVersion"] as? String ?? "",
      updates: UpdaterFacts(AppUpdater.shared.state), state: state)
  }

  func feedbackTarget() -> FeedbackTarget {
    AppDiagnostics.feedback(report: diagnostics(), app: AppFacts(AppModule.systemInfo))
  }

  func sendFeedback(_ windowId: String?) {
    switch feedbackTarget() {
    case .page(let url):
      openTab(url, in: windowId)
    case .mail(let draft, let body):
      if ProcessInfo.processInfo.environment["ARDIA_BACKGROUND"] == "1" { return NSLog("[services] background instance, not opening the feedback mail draft") }
      if !(URL(string: draft).map { NSWorkspace.shared.open($0) } ?? false) { Self.copy(body) }
    }
  }

  private func openTab(_ url: String, in windowId: String?) {
    guard let store = NativeStoreHandle.store else { return }
    let state = store.state
    if let target = state.resolveWindowId(windowId), state.windows[target]?.incognito != true {
      _ = try? store.dispatch(Command("newTab", [.string(target), ["url": .string(url)]]), origin: .native)
    } else {
      _ = try? store.dispatch(Command("createWindow", [["url": .string(url)]]), origin: .native)
    }
  }

  private func recordPerformanceIssue() {
    guard !ArdiaCoreHost.isTracing else { return }
    let product = Bundle.main.productName
    guard Self.confirm(
      "Record a performance issue?",
      "\(product) records what the engine does while you reproduce the problem. The recording is saved to your Downloads folder.",
      confirm: "Start Recording")
    else { return }
    ArdiaCoreHost.beginTracing { started in
      guard started else { return }
      let keep = Self.confirm("Recording…", "Reproduce the problem now, then click Stop.", confirm: "Stop", cancel: "Discard")
      ArdiaCoreHost.endTracing(keep: keep) { path in
        guard let path, FileManager.default.fileExists(atPath: path) else { return }
        if ProcessInfo.processInfo.environment["ARDIA_BACKGROUND"] == "1" { return NSLog("[services] recording saved to %@", path) }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
      }
    }
  }

  private static func confirm(_ title: String, _ message: String, confirm: String, cancel: String = "Cancel") -> Bool {
    let alert = NSAlert()
    alert.messageText = title
    alert.informativeText = message
    alert.addButton(withTitle: confirm)
    alert.addButton(withTitle: cancel)
    return alert.runModal() == .alertFirstButtonReturn
  }

  static func copy(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
  }
}

@MainActor
final class PooledScriptPages: ScriptPages {
  func has(_ tabId: String) -> Bool { TabPoolHost.shared.pageView(tabId) != nil }

  func call(_ tabId: String, _ method: String, _ args: [Any], done: @escaping (Any?, String?) -> Void) {
    guard let page = TabPoolHost.shared.pageView(tabId) else { return done(nil, "The tab hasn't loaded yet; focus it first.") }
    PageCalls.run(page, method, args, resolve: { done($0, nil) }, reject: { _, message in done(nil, message) })
  }
}
