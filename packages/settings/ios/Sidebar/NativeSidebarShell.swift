import AppKit
import ArdiaShell
import Foundation
import SolaraUI

@MainActor
enum NativeSidebarShell {
  nonisolated static let topic = "sidebar.shell"
  private static var observer: UUID?
  private static var shellAppeared: NSObjectProtocol?
  private static var columns: [String: SidebarShellColumn] = [:]

  nonisolated static var enabled: Bool {
    NativeWindowShell.enabled && NativeSidebar.enabled
  }

  static func register() {
    guard enabled, observer == nil else { return }
    HostedViews.register(topic) { _ in nil }
    observer = SettingsJS.shared.observe(topic) { value in receive(value) }
    shellAppeared = NotificationCenter.default.addObserver(forName: Notification.Name("RCTContentDidAppearNotification"), object: nil, queue: .main) { note in
      guard note.object is WindowShellView else { return }
      MainActor.assumeIsolated { receive(SettingsJS.shared.latestValue(topic)) }
    }
    receive(SettingsJS.shared.latestValue(topic))
  }

  static func column(_ windowId: String) -> SidebarShellColumn? { columns[windowId] }

  static func describe(_ windowId: String) -> String {
    guard let column = columns[windowId], let data = try? JSONSerialization.data(withJSONObject: column.describe()) else { return "null" }
    return String(data: data, encoding: .utf8) ?? "null"
  }

  private static func receive(_ value: Any?) {
    let windows = ((value as? [String: Any])?["windows"] as? [String: Any]) ?? [:]
    for (windowId, column) in columns where windows[windowId] == nil { remove(windowId, column) }
    for (windowId, given) in windows {
      guard let given = given as? [String: Any], let state = given["state"] as? String, let column = columns[windowId] ?? make(windowId) else { continue }
      let number = { (key: String) in CGFloat((given[key] as? NSNumber)?.doubleValue ?? 0) }
      column.apply(
        state: state,
        layout: SidebarShellColumn.Layout(top: number("top"), header: number("header"), bottom: number("bottom"), clip: (given["clip"] as? Bool) ?? false))
    }
  }

  private static func make(_ windowId: String) -> SidebarShellColumn? {
    guard let shell = NativeWindowShell.host(windowId)?.shell else { return nil }
    let host = SidebarHost(windowId: windowId)
    NativeSidebar.hosts[windowId] = host
    let column = SidebarShellColumn(windowId: windowId, host: host)
    columns[windowId] = column
    shell.mount(.sidebar, column)
    return column
  }

  private static func remove(_ windowId: String, _ column: SidebarShellColumn) {
    columns[windowId] = nil
    if let shell = NativeWindowShell.host(windowId)?.shell, shell.view(in: .sidebar) === column { shell.mount(.sidebar, nil) }
    column.removeFromSuperview()
    column.host.stop()
    if NativeSidebar.hosts[windowId] === column.host { NativeSidebar.hosts[windowId] = nil }
  }

  static func dropped(_ windowId: String, items: [[String: String]], placement: String?) {
    let payload = SidebarPayload(["items": items, "placement": placement ?? NSNull()])
    Task { @MainActor in
      _ = await SettingsAdapters.js(topic, windowId, "drop", payload.value)
    }
  }
}

@MainActor
final class SidebarShellColumn: NSView, DevDropDestination {
  struct Layout: Equatable {
    var top: CGFloat = 0
    var header: CGFloat = 0
    var bottom: CGFloat = 0
    var clip = false
  }

  static let resizeStrip: CGFloat = 4

  let windowId: String
  let host: SidebarHost
  private let list = FlippedContainerView()
  private var given = Layout()
  private var dropCount = 0

  override var isFlipped: Bool { true }

  init(windowId: String, host: SidebarHost) {
    self.windowId = windowId
    self.host = host
    super.init(frame: .zero)
    list.wantsLayer = true
    list.autoresizingMask = []
    host.view.autoresizingMask = [.width, .height]
    list.addSubview(host.view)
    addSubview(list)
    registerForDraggedTypes([.fileURL, .URL, .string])
  }

  required init?(coder: NSCoder) { fatalError() }

  func apply(state: String, layout: Layout) {
    if layout != given {
      given = layout
      list.layer?.masksToBounds = layout.clip
      placeList()
    }
    host.apply(state)
  }

  override func setFrameSize(_ newSize: NSSize) {
    super.setFrameSize(newSize)
    placeList()
  }

  private func placeList() {
    list.frame = CGRect(x: 0, y: given.top, width: bounds.width, height: max(0, bounds.height - given.top - given.bottom))
    host.view.frame = list.bounds
  }

  override func hitTest(_ point: NSPoint) -> NSView? {
    let local = convert(point, from: superview)
    guard local.y >= given.header, local.y < bounds.height - given.bottom, local.x < bounds.width - Self.resizeStrip else { return nil }
    let hit = super.hitTest(point)
    return hit === self ? nil : hit
  }

  func describe() -> [String: Any] {
    let inWindow = convert(bounds, to: nil)
    let list = host.view.convert(host.view.bounds, to: nil)
    let height = window?.contentView?.bounds.height ?? 0
    let rect = { (r: CGRect) -> [Double] in [r.minX, height - r.maxY, r.width, r.height] }
    return [
      "frame": rect(inWindow), "list": rect(list), "header": given.header, "bottom": given.bottom, "clip": given.clip,
      "slot": (superview as? WindowShellView)?.slot(of: self)?.rawValue ?? NSNull(), "hidden": isHiddenOrHasHiddenAncestor,
      "hover": host.view.current?.hoverKey ?? NSNull(),
      "reactUnder": reactUnderList().map { [$0.0, $0.1.minX, height - $0.1.maxY, $0.1.width, $0.1.height] },
    ]
  }

  private func reactUnderList() -> [(String, CGRect)] {
    #if DEBUG
    guard let shell = superview as? WindowShellView, let react = shell.view(in: .react), let window else { return [] }
    let list = host.view.convert(host.view.bounds, to: nil)
    var found: [(String, CGRect)] = []
    func visit(_ view: NSView) {
      guard !view.isHidden, view.alphaValue > 0.01 else { return }
      let box = view.convert(view.bounds, to: nil)
      if view !== react, box.intersects(list), Self.draws(view) { found.append((NSStringFromClass(type(of: view)), box)) }
      for child in view.subviews { visit(child) }
    }
    if window.contentView != nil { visit(react) }
    return found
    #else
    return []
    #endif
  }

  private static func draws(_ view: NSView) -> Bool {
    let name = NSStringFromClass(type(of: view))
    guard name.hasPrefix("RCT"), !name.contains("Text"), !name.contains("Image") else { return true }
    if view.responds(to: Selector(("backgroundColor"))), let color = view.value(forKey: "backgroundColor") as? NSColor, (color.usingColorSpace(.sRGB)?.alphaComponent ?? 1) > 0 { return true }
    return view.layer?.contents != nil || (view.layer?.backgroundColor?.alpha ?? 0) > 0
  }

  private func windowPoint(_ info: NSDraggingInfo) -> CGPoint {
    CGPoint(x: info.draggingLocation.x, y: (window?.contentView?.bounds.height ?? 0) - info.draggingLocation.y)
  }

  private func operation(_ info: NSDraggingInfo) -> NSDragOperation {
    guard dropCount > 0 else { return [] }
    let mask = info.draggingSourceOperationMask
    if mask.contains(.copy) { return .copy }
    if mask.contains(.generic) { return .generic }
    return mask.contains(.link) ? .link : []
  }

  override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
    dropCount = DroppedLinks.count(sender.draggingPasteboard)
    guard dropCount > 0 else { return [] }
    _ = NativeSidebarDrag.external(windowId: windowId, phase: "enter", at: windowPoint(sender), count: dropCount)
    return operation(sender)
  }

  override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
    guard dropCount > 0 else { return [] }
    _ = NativeSidebarDrag.external(windowId: windowId, phase: "move", at: windowPoint(sender), count: dropCount)
    return operation(sender)
  }

  override func draggingExited(_ sender: NSDraggingInfo?) { leave() }

  override func draggingEnded(_ sender: NSDraggingInfo) { leave() }

  private func leave() {
    guard dropCount > 0 else { return }
    dropCount = 0
    _ = NativeSidebarDrag.external(windowId: windowId, phase: "leave", at: .zero, count: 0)
  }

  override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { dropCount > 0 }

  override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
    guard dropCount > 0 else { return false }
    dropCount = 0
    let items = DroppedLinks.items(sender.draggingPasteboard)
    let placement = NativeSidebarDrag.external(windowId: windowId, phase: "drop", at: windowPoint(sender), count: items.count)
    NativeSidebarShell.dropped(windowId, items: items, placement: placement)
    return !items.isEmpty
  }
}
