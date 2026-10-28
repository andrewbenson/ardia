import AppKit
import ArdiaCore
import SolaraModel
import SolaraOmnibox
import SolaraStore
import SolaraUI

@MainActor
final class TabPoolHost {
  static let shared = TabPoolHost()

  nonisolated static var available: Bool { NativeSplitChrome.panesEnabled && NativePaneRoots.available && NativeStoreHandle.opened
    && ProcessInfo.processInfo.environment["ARDIA_TAB_POOL"] != "0" }

  var emit: ((String, [String: Any]) -> Void)?
  var onPageGone: ((String) -> Void)?
  private var pool: TabViewPool?
  private var listener: Int?
  private var slotObserver: NSObjectProtocol?
  private var overlaysObserver: NSObjectProtocol?
  private var cardPageFollows: [String: (slot: NSView, observer: NSObjectProtocol)] = [:]
  private let commits = TabPoolCommits()
  private var state: BrowserState?
  private var props: [String: [String: Any]] = [:]
  private var pages: [String: PoolPage] = [:]
  private var warm: Set<String> = []
  private var shellWindows: Set<String> = []

  func start() {
    guard pool == nil else { return }
    guard Self.available, let store = NativeStoreHandle.store else { return startWhenSlotsChange() }
    if let slotObserver { NotificationCenter.default.removeObserver(slotObserver) }
    let pool = TabViewPool(make: { [weak self] tabId, windowId in self?.makePage(tabId, windowId) })
    pool.hiddenContainer = { NativeWindowShell.hiddenPages($0) }
    pool.onPlaced = { [weak self] places in self?.emit?("onPlaced", ["places": places]) }
    self.pool = pool
    commits.host = self
    let sink = commits
    listener = store.subscribe { commit in sink.receive(commit.state) }
    slotObserver = NotificationCenter.default.addObserver(forName: TabSlots.changed, object: TabSlots.shared, queue: nil) { [weak self] _ in
      MainActor.assumeIsolated { self?.refresh() }
    }
    overlaysObserver = NotificationCenter.default.addObserver(forName: PaneOverlays.changed, object: PaneOverlays.shared, queue: nil) { [weak self] _ in
      MainActor.assumeIsolated { self?.followCardPages() }
    }
    receive(store.state)
  }

  private func startWhenSlotsChange() {
    guard slotObserver == nil, NativeSplitChrome.panesEnabled, ProcessInfo.processInfo.environment["ARDIA_TAB_POOL"] != "0" else { return }
    slotObserver = NotificationCenter.default.addObserver(forName: TabSlots.changed, object: TabSlots.shared, queue: nil) { [weak self] _ in
      MainActor.assumeIsolated { self?.start() }
    }
  }

  func pageView(_ tabId: String) -> NSView? { pages[tabId]?.page.view }

  func setPageProps(_ tabId: String, _ changed: [String: Any]) {
    props[tabId, default: [:]].merge(changed) { _, new in new }
    pages[tabId]?.page.apply(changed)
  }

  func receive(_ next: BrowserState) {
    state = next
    for tabId in props.keys where next.tabs[tabId] == nil { props[tabId] = nil }
    refresh()
  }

  private func refresh() {
    guard let pool, let state else { return }
    shellWindows.formUnion(NativeWindowShell.activeWindowIds)
    shellWindows = shellWindows.filter { state.windows[$0] != nil }
    let wanted = TabViewWanted.from(state, windows: shellWindows, isInternal: Self.isInternal, frozen: { _ in false })
    warm = Set(wanted.filter(\.warm).map(\.tabId))
    for page in pages.values { page.setWarm(warm.contains(page.tabId), neighbour: Self.neighbour(state, page.tabId)) }
    pool.update(wanted)
    followCardPages()
  }

  private func followCardPages() {
    guard let state else { return }
    var seen: Set<String> = []
    for windowId in NativeWindowShell.activeWindowIds {
      guard let shell = NativeWindowShell.host(windowId)?.shell, let window = state.windows[windowId] else { continue }
      seen.insert(windowId)
      let active = window.activeTabIds[window.profileId]
      let slot = active.flatMap { PaneOverlays.shared.container(windowId: windowId, tabId: $0, layer: .native)?.superview }
      if cardPageFollows[windowId]?.slot !== slot {
        if let old = cardPageFollows.removeValue(forKey: windowId) { NotificationCenter.default.removeObserver(old.observer) }
        if let slot {
          slot.postsFrameChangedNotifications = true
          let observer = NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: slot, queue: nil) { [weak self] _ in
            MainActor.assumeIsolated { self?.followCardPages() }
          }
          cardPageFollows[windowId] = (slot, observer)
        }
      }
      shell.cardPageFrame = slot.flatMap { $0.superview == nil ? nil : $0.convert($0.bounds, to: shell.card) }
    }
    for (windowId, follow) in cardPageFollows where !seen.contains(windowId) {
      NotificationCenter.default.removeObserver(follow.observer)
      cardPageFollows[windowId] = nil
    }
  }

  private func makePage(_ tabId: String, _ windowId: String) -> TabPoolPage? {
    guard let state, let store = NativeStoreHandle.store, let tab = state.tabs[tabId] else { return nil }
    let peek = state.peeks[windowId]
    let url = tab.navigation?.url ?? (tab.adoptId != nil ? tab.url : nil)
    let spec = PooledPageSpec(
      engine: store.pageEngine(tabId, in: state), profile: state.engineProfile(tab.profileId), url: url.map(toEngineUrl),
      adoptId: tab.adoptId, temporarySource: peek?.tabId == tabId ? peek?.sourceId : nil)
    let page = PooledPage(tabId: tabId, spec: spec) { [weak self] name, payload in
      self?.emit?("onPageEvent", ["tabId": tabId, "name": name, "payload": payload])
    }
    if let given = props[tabId] { page.apply(given) }
    let entry = PoolPage(page: page) { [weak self] in
      guard let self, self.pages[tabId]?.page === page else { return }
      self.pages[tabId] = nil
      self.onPageGone?(tabId)
      self.emit?("onPageEvent", ["tabId": tabId, "name": "onPageGone", "payload": [String: Any]()])
    }
    entry.setWarm(warm.contains(tabId), neighbour: Self.neighbour(state, tabId))
    pages[tabId] = entry
    let seq = tab.adoptId == nil ? tab.navigation?.seq ?? -1 : -1
    emit?("onPageEvent", ["tabId": tabId, "name": "onPageCreated", "payload": ["engine": spec.engine, "seq": seq, "url": spec.url ?? ""]])
    return entry
  }

  static func neighbour(_ state: BrowserState, _ tabId: String) -> Bool {
    guard let tab = state.tabs[tabId], let window = state.windows[tab.windowId] else { return false }
    return window.profileId != tab.profileId
  }

  static func isInternal(_ tab: Tab) -> Bool {
    let url = tab.navigation?.url ?? tab.url
    guard let colon = url.range(of: "://") else { return false }
    let scheme = String(url[..<colon.lowerBound])
    guard isAppScheme(scheme) else { return false }
    let rest = url[colon.upperBound...]
    let host = rest.prefix { $0 != "/" && $0 != "?" && $0 != "#" }.lowercased()
    return ["history", "bookmarks", "downloads"].contains(host)
  }
}

@MainActor
final class PoolPage: TabPoolPage {
  let page: PooledPage
  var tabId: String { page.tabId }
  private var shown = false
  private var warm = false
  private var neighbour = false
  private let onRetire: () -> Void

  init(page: PooledPage, onRetire: @escaping () -> Void) {
    self.page = page
    self.onRetire = onRetire
  }

  var view: NSView { page.view }

  func setShown(_ shown: Bool) {
    self.shown = shown
    apply()
  }

  func setWarm(_ warm: Bool, neighbour: Bool) {
    self.warm = warm
    self.neighbour = warm && neighbour
    apply()
  }

  func retire() {
    page.retire()
    onRetire()
  }

  private func apply() {
    page.setShown(shown, warm: warm && !shown, neighbour: neighbour && !shown)
  }
}

final class TabPoolCommits: @unchecked Sendable {
  weak var host: TabPoolHost?
  private let lock = NSLock()
  private var latest: BrowserState?
  private var scheduled = false

  func receive(_ state: BrowserState) {
    let schedule = lock.withLock { () -> Bool in
      latest = state
      if scheduled { return false }
      scheduled = true
      return true
    }
    guard schedule else { return }
    DispatchQueue.main.async { [self] in
      let next = lock.withLock { () -> BrowserState? in
        scheduled = false
        defer { latest = nil }
        return latest
      }
      guard let next else { return }
      MainActor.assumeIsolated { host?.receive(next) }
    }
  }
}
