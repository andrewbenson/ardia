import AppKit
import SolaraModel

@MainActor
public final class SidebarPagerView: NSView {
  public let windowId: String
  public let favicons = SidebarFavicons()
  public var onAction: (SidebarAction) -> Void = { _ in }

  private var pages: [String: SidebarView] = [:]
  private var stale: Set<String> = []
  private var state: BrowserState?
  private var host: SidebarHostState?
  private var pagerPosition: Double?
  private var warm: DispatchWorkItem?

  static let warmDelay: TimeInterval = 0.3

  public override var isFlipped: Bool { true }

  public init(windowId: String) {
    self.windowId = windowId
    super.init(frame: .zero)
    wantsLayer = true
    layer?.masksToBounds = true
  }

  required init?(coder: NSCoder) { fatalError() }

  public var current: SidebarView? { host.flatMap { pages[$0.profileId] } }

  public var pageIds: [String] { order }

  public func describePages() -> [[String: Any]] {
    order.compactMap { id in
      guard let page = pages[id] else { return ["id": id, "made": false] }
      return ["id": id, "made": true, "x": page.frame.minX, "hidden": page.isHidden, "docked": page.pageLayout.docked, "current": id == host?.profileId]
    } + [["position": position]]
  }

  public func update(state: BrowserState, host: SidebarHostState) {
    self.state = state
    if self.host?.profileId != host.profileId, let pagerPosition, abs(pagerPosition - pagerPosition.rounded()) < 0.001 { self.pagerPosition = nil }
    self.host = host
    stale = Set(pages.keys)
    for id in pages.keys where !order.contains(id) {
      pages[id]?.removeFromSuperview()
      pages[id] = nil
      stale.remove(id)
    }
    place()
    scheduleWarm()
  }

  public func setPagerPosition(_ position: Double) {
    pagerPosition = position
    place()
  }

  public override func layout() {
    super.layout()
    place()
  }

  private var order: [String] {
    guard let host else { return [] }
    guard let looks = host.pages, let state else { return [host.profileId] }
    let paged = Set(looks.map(\.profileId))
    let ids = state.profileOrder.filter { paged.contains($0) }
    return ids.contains(host.profileId) ? ids : [host.profileId]
  }

  var position: Double {
    let ids = order
    let home = Double(ids.firstIndex(of: host?.profileId ?? "") ?? 0)
    guard ids.count > 1, let pagerPosition else { return home }
    return pagerPosition
  }

  private func place() {
    guard let host, state != nil, bounds.width > 0 else { return }
    let ids = order
    let at = position
    for (slot, id) in ids.enumerated() {
      let offset = Double(slot) - at
      let shown = abs(offset) < 1 || id == host.profileId && ids.count == 1
      if !shown {
        pages[id]?.isHidden = true
        continue
      }
      let page = page(id)
      if stale.contains(id) { refresh(id) }
      let frame = NSRect(x: (offset * bounds.width).rounded(), y: 0, width: bounds.width, height: bounds.height)
      if page.frame != frame { page.frame = frame }
      page.isHidden = false
    }
  }

  private func page(_ id: String) -> SidebarView {
    if let page = pages[id] { return page }
    let page = SidebarView(windowId: windowId, favicons: favicons)
    page.onAction = { [weak self] action in self?.onAction(action) }
    page.isHidden = true
    pages[id] = page
    stale.insert(id)
    addSubview(page)
    return page
  }

  private func refresh(_ id: String) {
    guard let state, let host, let page = pages[id] else { return }
    stale.remove(id)
    let pageHost = id == host.profileId ? host : host.pages?.first { $0.profileId == id }.map(host.page) ?? host
    if page.frame.size != bounds.size { page.frame.size = bounds.size }
    page.update(state: state, host: pageHost)
  }

  private func scheduleWarm() {
    warm?.cancel()
    let work = DispatchWorkItem { [weak self] in
      guard let self, let host else { return }
      let ids = order
      guard let home = ids.firstIndex(of: host.profileId) else { return }
      for slot in [home - 1, home + 1] where slot >= 0 && slot < ids.count {
        let id = ids[slot]
        _ = page(id)
        if stale.contains(id) { refresh(id) }
      }
    }
    warm = work
    DispatchQueue.main.asyncAfter(deadline: .now() + Self.warmDelay, execute: work)
  }
}
