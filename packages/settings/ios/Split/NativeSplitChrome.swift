import AppKit
import Foundation
import SolaraModel
import SolaraStore
import SolaraUI

@MainActor
enum NativeSplitChrome {
  static let themeTopic = "split.theme"
  static let dragTopic = "split.drag"
  static let toastTopic = "split.toast"

  private static var started = false
  private static var views: [String: SplitChromeView] = [:]
  private static var listener: Int?
  private static let commits = SplitChromeCommits()

  static func start() {
    guard NativeWindowShell.enabled, !started else { return }
    started = true
    _ = SettingsJS.shared.observe(themeTopic) { value in applyTheme(value) }
    _ = SettingsJS.shared.observe(dragTopic) { value in applyDrag(value) }
    _ = SettingsJS.shared.observe(toastTopic) { value in applyToast(value) }
    #if DEBUG
    _ = SettingsJS.shared.observe("split.dev") { value in SplitChromeDevRun.start(value, views) }
    #endif
    if let store = NativeStoreHandle.store {
      let sink = commits
      listener = store.subscribe { commit in sink.receive(commit.state) }
    }
    applyTheme(SettingsJS.shared.latestValue(themeTopic))
  }

  static func commit(_ state: BrowserState) {
    for (id, view) in views {
      if view.superview == nil { views[id] = nil } else { view.update(state: state) }
    }
  }

  private static func view(_ windowId: String) -> SplitChromeView? {
    if let view = views[windowId], view.superview != nil { return view }
    views[windowId] = nil
    guard let host = NativeWindowShell.host(windowId) else { return nil }
    let view = SplitChromeView(windowId: windowId)
    view.onResize = { splitId, sizes, stack in
      var options: JSONObject = [:]
      if let sizes { options["sizes"] = .array(sizes.map { .number($0) }) }
      if let stack { options["stackSizes"] = .array(stack.map { .number($0) }) }
      _ = try? NativeStoreHandle.store?.dispatch(Command("updateSplit", [.string(splitId), .object(options)]), origin: .native)
    }
    view.onToastHidden = { id in Task { @MainActor in _ = await SettingsAdapters.js("split.toast", windowId, id, "hidden") } }
    view.onToastAction = { id in Task { @MainActor in _ = await SettingsAdapters.js("split.toast", windowId, id, "action") } }
    host.shell.mount(.splitChrome, view)
    if let state = NativeStoreHandle.store?.state { view.update(state: state) }
    views[windowId] = view
    return view
  }

  private static func windows(_ value: Any?) -> [String: [String: Any]]? {
    guard let o = value as? [String: Any], o["v"] as? Int == 1 else { return nil }
    return o["windows"] as? [String: [String: Any]]
  }

  private static func applyTheme(_ value: Any?) {
    guard let all = windows(value) else { return }
    for (windowId, entry) in all {
      guard let view = view(windowId) else { continue }
      view.setChrome(theme: SplitChromeTheme(entry["theme"] as? [String: Any] ?? [:]), fullscreenTab: entry["fullscreenTab"] as? String, covered: entry["covered"] as? Bool ?? false)
    }
  }

  private static func applyDrag(_ value: Any?) {
    guard let o = value as? [String: Any], let windowId = o["windowId"] as? String else { return }
    for (id, view) in views where id != windowId { view.setDrag(nil) }
    view(windowId)?.setDrag(SplitDragFrame(o))
  }

  private static func applyToast(_ value: Any?) {
    guard let all = windows(value) else { return }
    for (windowId, entry) in all {
      view(windowId)?.setToast(SplitToastSpec(entry))
    }
    for (id, view) in views where all[id] == nil { view.setToast(nil) }
  }

  static func sample(_ windowId: String) -> [String: Any]? { views[windowId]?.sample() }
}

final class SplitChromeCommits: @unchecked Sendable {
  private let lock = NSLock()
  private var latest: BrowserState?
  private var scheduled = false

  func receive(_ state: BrowserState) {
    if Thread.isMainThread {
      lock.withLock { latest = nil }
      MainActor.assumeIsolated { NativeSplitChrome.commit(state) }
      return
    }
    let schedule = lock.withLock { () -> Bool in
      latest = state
      if scheduled { return false }
      scheduled = true
      return true
    }
    guard schedule else { return }
    DispatchQueue.main.async { [self] in
      let state = lock.withLock { () -> BrowserState? in
        scheduled = false
        defer { latest = nil }
        return latest
      }
      guard let state else { return }
      MainActor.assumeIsolated { NativeSplitChrome.commit(state) }
    }
  }
}

#if DEBUG
@MainActor
final class SplitChromeDevRun {
  private static var current: SplitChromeDevRun?
  private let run: Int
  private let view: SplitChromeView?
  private let steps: Int
  private let step: CGFloat
  private var frame = 0
  private var timer: Timer?
  private var observer: CFRunLoopObserver?
  private var woke: CFAbsoluteTime?
  private var busy: Double = 0
  private var longest: Double = 0
  private var iterations = 0
  private let dispatchesBefore: Int
  private let began = CFAbsoluteTimeGetCurrent()

  static func start(_ value: Any?, _ views: [String: SplitChromeView]) {
    guard let o = value as? [String: Any], o["v"] as? Int == 1, let run = o["run"] as? Int, let windowId = o["windowId"] as? String else { return }
    let native = o["mode"] as? String == "native"
    let view = native ? views[windowId] : nil
    if native, view?.devDragBegin(o["key"] as? String ?? "r0") != true {
      Task { @MainActor in _ = await SettingsAdapters.js("split.devResult", run, "{\"error\": \"no divider\"}") }
      return
    }
    current = SplitChromeDevRun(run: run, view: view, steps: o["steps"] as? Int ?? 60, step: CGFloat((o["step"] as? NSNumber)?.doubleValue ?? 4))
  }

  private init(run: Int, view: SplitChromeView?, steps: Int, step: CGFloat) {
    self.run = run
    self.view = view
    self.steps = steps
    self.step = step
    dispatchesBefore = view?.dispatches ?? 0
    let activities = CFRunLoopActivity.afterWaiting.rawValue | CFRunLoopActivity.beforeWaiting.rawValue
    observer = CFRunLoopObserverCreateWithHandler(nil, activities, true, 2_000_001) { [weak self] _, activity in
      MainActor.assumeIsolated { self?.observe(activity) }
    }
    CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
    let made = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.tick() } }
    made.tolerance = 0
    RunLoop.main.add(made, forMode: .common)
    timer = made
  }

  private func observe(_ activity: CFRunLoopActivity) {
    let now = CFAbsoluteTimeGetCurrent()
    if activity == .afterWaiting {
      woke = now
    } else if let woke {
      let spent = (now - woke) * 1000
      busy += spent
      longest = max(longest, spent)
      iterations += 1
      self.woke = nil
    }
  }

  private func tick() {
    frame += 1
    if frame <= steps {
      view?.devDragMove(step * CGFloat(frame))
      if frame == steps { view?.devDragEnd() }
      return
    }
    guard frame >= steps + 6 else { return }
    timer?.invalidate()
    if let observer { CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes) }
    let result: [String: Any] = [
      "busy": busy, "longest": longest, "iterations": iterations, "ms": (CFAbsoluteTimeGetCurrent() - began) * 1000,
      "dispatches": (view?.dispatches ?? 0) - dispatchesBefore, "frames": steps,
    ]
    let run = run
    let json = (try? JSONSerialization.data(withJSONObject: result)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    Task { @MainActor in _ = await SettingsAdapters.js("split.devResult", run, json) }
    if Self.current === self { Self.current = nil }
  }
}
#endif
