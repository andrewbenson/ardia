import AppKit

@MainActor
public protocol TabPoolPage: AnyObject {
  var view: NSView { get }
  func setShown(_ shown: Bool)
  func focus()
  func retire()
}

@MainActor
public final class TabViewPool {
  public typealias Make = @MainActor (_ tabId: String, _ windowId: String) -> TabPoolPage?
  public typealias Schedule = @MainActor (@escaping @MainActor () -> Void) -> Void

  public let slots: TabSlots
  public let keeper: NSView
  public var hiddenContainer: @MainActor (String) -> NSView? = { _ in nil }
  public var onPlaced: (@MainActor ([String: String]) -> Void)?
  public var onReplace: (@MainActor (String) -> Void)?

  private let make: Make
  private let schedule: Schedule
  private var wanted: [TabViewWanted] = []
  private var pages: [String: TabPoolPage] = [:]
  private var places: [String: TabViewPlace] = [:]
  private var shown: [String: Bool] = [:]
  private var identities: [String: String] = [:]
  private var refocus: Set<String> = []
  private var scheduled = false
  private var slotObserver: NSObjectProtocol?

  public init(slots: TabSlots = .shared, make: @escaping Make, schedule: @escaping Schedule = { work in DispatchQueue.main.async { MainActor.assumeIsolated(work) } }) {
    self.slots = slots
    self.make = make
    self.schedule = schedule
    keeper = NSView(frame: .zero)
    keeper.isHidden = true
    slotObserver = NotificationCenter.default.addObserver(forName: TabSlots.changed, object: slots, queue: nil) { [weak self] _ in
      MainActor.assumeIsolated { self?.setNeedsReconcile() }
    }
  }

  isolated deinit {
    if let slotObserver { NotificationCenter.default.removeObserver(slotObserver) }
  }

  public func page(_ tabId: String) -> TabPoolPage? { pages[tabId] }
  public func place(_ tabId: String) -> TabViewPlace? { places[tabId] }

  public func update(_ wanted: [TabViewWanted]) {
    guard wanted != self.wanted else { return }
    self.wanted = wanted
    setNeedsReconcile()
  }

  public func setNeedsReconcile() {
    guard !scheduled else { return }
    scheduled = true
    schedule { [weak self] in self?.reconcile() }
  }

  public func reconcile() {
    scheduled = false
    let replaced = retireChangedIdentities()
    let ops = TabViewPlan.plan(wanted: wanted, slots: slots.keys, current: places, visible: shown)
    let rehosted = rehost()
    guard !ops.isEmpty else {
      focusReplaced()
      if rehosted || replaced { onPlaced?(places.mapValues(Self.describe)) }
      return
    }
    var made: Set<String> = []
    for op in ops {
      if case .visible(let id, false) = op { pages[id]?.setShown(false) }
    }
    for op in ops {
      switch op {
      case .drop(let id):
        identities[id] = nil
        guard let page = pages.removeValue(forKey: id) else { continue }
        page.retire()
      case .create(let id, let windowId):
        guard let page = make(id, windowId) else { continue }
        pages[id] = page
        identities[id] = identity(of: id)
        made.insert(id)
        move(page.view, into: hidden(windowId), below: false)
      case .attach(let id, let key, _):
        guard let view = pages[id]?.view, let container = slots.container(for: key) else { continue }
        move(view, into: container, below: false)
      case .behind(let id, let key, _):
        guard let view = pages[id]?.view, let container = slots.container(for: key) else { continue }
        move(view, into: container, below: true)
      case .hide(let id, let windowId, _):
        guard let view = pages[id]?.view else { continue }
        move(view, into: hidden(windowId), below: false)
      case .visible(let id, let on):
        if on { pages[id]?.setShown(true) }
      }
    }
    var applied = TabViewPlan.apply(ops, to: places, visible: shown)
    for op in ops {
      if case .create(let id, _) = op, !made.contains(id) {
        applied.current[id] = nil
        applied.visible[id] = nil
      }
    }
    places = applied.current
    shown = applied.visible
    focusReplaced()
    onPlaced?(places.mapValues(Self.describe))
  }

  private func focusReplaced() {
    let ids = refocus
    refocus = []
    for id in ids.sorted() {
      guard let page = pages[id], page.view.window != nil, !page.view.isHiddenOrHasHiddenAncestor else { continue }
      page.focus()
    }
  }

  private func retireChangedIdentities() -> Bool {
    var replaced = false
    for entry in wanted where !entry.identity.isEmpty {
      guard pages[entry.tabId] != nil else { continue }
      guard let had = identities[entry.tabId], !had.isEmpty else {
        identities[entry.tabId] = entry.identity
        continue
      }
      guard had != entry.identity, let page = pages.removeValue(forKey: entry.tabId) else { continue }
      let responder = page.view.window?.firstResponder as? NSView
      if let responder, responder === page.view || responder.isDescendant(of: page.view) { refocus.insert(entry.tabId) }
      identities[entry.tabId] = nil
      places[entry.tabId] = nil
      shown[entry.tabId] = nil
      page.setShown(false)
      onReplace?(entry.tabId)
      page.retire()
      replaced = true
    }
    return replaced
  }

  private func identity(of tabId: String) -> String {
    wanted.first { $0.tabId == tabId }?.identity ?? ""
  }

  private func rehost() -> Bool {
    var moved = false
    for (id, place) in places.sorted(by: { $0.key < $1.key }) {
      guard let view = pages[id]?.view else { continue }
      let container: NSView?
      switch place {
      case .slot(let key), .behind(let key): container = slots.container(for: key)
      case .hidden(let windowId): container = hidden(windowId)
      }
      guard let container, view.superview !== container else { continue }
      if case .behind = place { move(view, into: container, below: true) } else { move(view, into: container, below: false) }
      moved = true
    }
    return moved
  }

  private func hidden(_ windowId: String) -> NSView {
    hiddenContainer(windowId) ?? keeper
  }

  private func move(_ view: NSView, into container: NSView, below: Bool) {
    let window = view.window
    let responder = window?.firstResponder as? NSView
    let hadFocus = responder.map { $0 === view || $0.isDescendant(of: view) } ?? false
    let poolViews = Set(pages.values.map { ObjectIdentifier($0.view) })
    let topPage = below ? nil : container.subviews.last { $0 !== view && poolViews.contains(ObjectIdentifier($0)) }
    if let topPage {
      container.addSubview(view, positioned: .above, relativeTo: topPage)
    } else {
      container.addSubview(view, positioned: .below, relativeTo: nil)
    }
    view.frame = container.bounds
    view.autoresizingMask = [.width, .height]
    if hadFocus, let responder, let now = view.window, now === window, now.firstResponder !== responder {
      now.makeFirstResponder(responder)
    }
  }

  static func describe(_ place: TabViewPlace) -> String {
    switch place {
    case .slot(.card): return "card"
    case .slot(.pane): return "pane"
    case .slot(.peek): return "peek"
    case .slot(.popup): return "popup"
    case .slot(.sidePanel): return "sidePanel"
    case .behind: return "behind"
    case .hidden: return "hidden"
    }
  }
}
