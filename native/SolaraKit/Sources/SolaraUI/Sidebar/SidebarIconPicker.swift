import AppKit
import QuartzCore

public struct SidebarIconPickerState: Decodable, Equatable, Sendable {
  public var id: String
  public var kind: String
  public var current: String?
  public var anchor: [Double]?
  public var sidebarWidth: Double
  public var dark: Bool
  public var shadowOpacity: Double
  public var theme: [String: String]
  public var emoji: [[String]]
  public var symbols: [String]

  public var anchorRect: CGRect? {
    guard let anchor, anchor.count == 4 else { return nil }
    return CGRect(x: anchor[0], y: anchor[1], width: anchor[2], height: anchor[3])
  }
}

public enum SidebarIconPickerTab: String, Sendable {
  case emoji
  case symbols
}

public enum SidebarIconPickerMetrics {
  public static let symbolPrefix = "symbol:"
  public static let noGroupIcon = "symbol:square.stack.fill"
  public static let width: CGFloat = 256
  static let border: CGFloat = 0.5
  static let padding: CGFloat = 8
  static let gap: CGFloat = 8
  static let radius: CGFloat = 14
  static let shadowRadius: CGFloat = 20
  static let shadowOffsetY: CGFloat = 8
  static let edge: CGFloat = 8
  static let anchorGap: CGFloat = 6
  static let fallbackAnchorY: CGFloat = 60
  static let search: CGFloat = 26
  static let searchRadius: CGFloat = 8
  static let searchPadding: CGFloat = 7
  static let glass: CGFloat = 14
  static let glassSymbol: CGFloat = 11
  static let fieldGap: CGFloat = 5
  static let fieldFont: CGFloat = 12
  static let tabWidth: CGFloat = 28
  static let tabGap: CGFloat = 6
  static let tabBox: CGFloat = 16
  static let tabSymbol: CGFloat = 13
  public static let cell: CGFloat = 30
  static let cellRadius: CGFloat = 8
  static let gridRows: CGFloat = 6
  static let emojiFont: CGFloat = 18
  static let cellBox: CGFloat = 20
  static let cellSymbol: CGFloat = 15
  static let footer: CGFloat = 26
  static let footerGap: CGFloat = 6
  static let footerInnerGap: CGFloat = 5
  static let footerBox: CGFloat = 14
  static let footerSymbol: CGFloat = 11
  static let label: CGFloat = 12
  static let emptyPadding: CGFloat = 8
  static var inset: CGFloat { border + padding }
  public static var inner: CGFloat { width - 2 * inset }
  public static var columns: Int { max(1, Int((inner / cell).rounded(.down))) }

  static func textOffset(box: CGFloat, text: CGFloat, scale: CGFloat) -> CGFloat {
    ((box - text - 0.001) / 2 * scale).rounded(.down) / scale
  }

  public static func origin(anchor: CGRect?, sidebarWidth: CGFloat) -> CGPoint {
    let top = max(edge, (anchor?.minY ?? fallbackAnchorY) - edge)
    let left = anchor.map { max(edge, min(sidebarWidth + anchorGap, $0.maxX + anchorGap)) } ?? sidebarWidth + anchorGap
    return CGPoint(x: left, y: top)
  }

  public static func items(_ state: SidebarIconPickerState, tab: SidebarIconPickerTab, query: String) -> [String] {
    let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    switch tab {
    case .emoji:
      return state.emoji.compactMap { pair in
        guard let emoji = pair.first else { return nil }
        return q.isEmpty || (pair.count > 1 && pair[1].contains(q)) ? emoji : nil
      }
    case .symbols:
      return state.symbols.filter { q.isEmpty || $0.contains(q) }.map { symbolPrefix + $0 }
    }
  }

  public static func showsFooter(_ state: SidebarIconPickerState) -> Bool {
    state.kind == "group" || state.current != nil
  }
}

public final class SidebarIconPickerView: NSView, NSTextFieldDelegate {
  public enum Event: Equatable {
    case choose(String?)
    case close
  }

  public var onEvent: ((Event) -> Void)?
  public private(set) var state: SidebarIconPickerState?
  public private(set) var tab: SidebarIconPickerTab = .emoji
  public private(set) var items: [String] = []
  public let panel = IconPickerPanelView()
  let field = IconPickerField()
  private let surface = SurfaceLayer()
  private let pill = CALayer()
  private let glass = SymbolView()
  private let tabButtons = [IconPickerTabButton(.emoji), IconPickerTabButton(.symbols)]
  private let scroll = NSScrollView()
  private let grid = IconPickerGridView()
  private let empty = OnboardingTextNSView()
  private let footerButtons = [IconPickerFooterButton(), IconPickerFooterButton()]
  private var emptyHeight: CGFloat = 0
  private var pressedOutside = false

  public override var isFlipped: Bool { true }

  public override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
    panel.wantsLayer = true
    panel.layer?.masksToBounds = false
    let m = SidebarIconPickerMetrics.self
    surface.radius = m.radius
    surface.border = m.border
    surface.glowColor = .black
    surface.glowRadius = m.shadowRadius
    surface.glowOffset = CGSize(width: 0, height: m.shadowOffsetY)
    panel.layer?.addSublayer(surface)
    pill.actions = SurfaceLayer.noActions
    pill.cornerRadius = m.searchRadius
    pill.cornerCurve = .circular
    panel.layer?.addSublayer(pill)
    panel.addSubview(glass)
    field.delegate = self
    panel.addSubview(field)
    for button in tabButtons {
      button.onPress = { [weak self] tab in self?.select(tab) }
      panel.addSubview(button)
    }
    scroll.drawsBackground = false
    scroll.hasVerticalScroller = false
    scroll.hasHorizontalScroller = false
    scroll.horizontalScrollElasticity = .none
    scroll.documentView = grid
    scroll.contentView.postsBoundsChangedNotifications = true
    NotificationCenter.default.addObserver(self, selector: #selector(scrolled), name: NSView.boundsDidChangeNotification, object: scroll.contentView)
    grid.onChoose = { [weak self] icon in self?.onEvent?(.choose(icon)) }
    panel.addSubview(scroll)
    empty.manager.usesFontLeading = false
    grid.addSubview(empty)
    for button in footerButtons {
      button.onPress = { [weak self, weak button] in
        guard let button else { return }
        self?.onEvent?(.choose(button.value))
      }
      panel.addSubview(button)
    }
    addSubview(panel)
    DevPointer.observe(self, #selector(devPointer(_:)))
  }

  required init?(coder: NSCoder) { fatalError() }

  public func set(_ next: SidebarIconPickerState) {
    let fresh = state?.id != next.id || state?.kind != next.kind
    state = next
    if fresh {
      tab = next.current?.hasPrefix(SidebarIconPickerMetrics.symbolPrefix) == true ? .symbols : .emoji
      field.stringValue = ""
      grid.hovered = nil
    }
    paint()
    refilter(scrollToTop: fresh)
  }

  public var query: String { field.stringValue }
  public var isEditing: Bool { (window?.firstResponder as? NSTextView)?.delegate === field }

  public func devInput(_ action: String) {
    if action.hasPrefix("type:") {
      focus()
      field.currentEditor()?.insertText(String(action.dropFirst(5)))
    } else if action == "escape" || action == "return" {
      focus()
      guard let editor = field.currentEditor() as? NSTextView else { return }
      _ = control(field, textView: editor, doCommandBy: action == "escape" ? #selector(NSResponder.cancelOperation(_:)) : #selector(NSResponder.insertNewline(_:)))
    } else if let next = SidebarIconPickerTab(rawValue: action) {
      select(next)
    }
  }

  public func focus() {
    window?.makeFirstResponder(field)
  }

  func select(_ next: SidebarIconPickerTab) {
    guard next != tab else { return }
    tab = next
    paint()
    refilter(scrollToTop: true)
  }

  private func color(_ key: String) -> NSColor? { state?.theme[key].flatMap { CSSColor($0)?.ns } }

  private func paint() {
    guard let state else { return }
    let m = SidebarIconPickerMetrics.self
    surface.fill = color("panel")
    surface.borderTint = color("panelBorder")
    surface.glowOpacity = state.shadowOpacity
    let hover = color("pickerCellHover")
    PrimitiveMotion.setInstantly { pill.backgroundColor = color("urlPill")?.cgColor }
    glass.set("magnifyingglass", size: m.glassSymbol, color: color("textSecondary") ?? .secondaryLabelColor)
    field.apply(text: color("textPrimary") ?? .labelColor, placeholder: tab == .emoji ? "Search emoji" : "Search icons", placeholderColor: color("placeholder") ?? .placeholderTextColor)
    field.appearance = NSAppearance(named: state.dark ? .darkAqua : .aqua)
    for button in tabButtons {
      button.set(selected: button.tab == tab, hover: hover, icon: color("icon") ?? .labelColor)
    }
    grid.palette = IconPickerGridView.Palette(hover: hover?.cgColor, icon: color("icon") ?? .labelColor)
    grid.current = state.current
    let ink = color("noGroupIconInk") ?? .tertiaryLabelColor
    var footer: [(label: String, icon: String?, symbol: String?, selected: Bool)] = []
    if state.kind == "group" { footer.append(("No Icon", m.noGroupIcon, "square.stack.fill", state.current == m.noGroupIcon)) }
    if state.current != nil { footer.append(("Reset Icon", nil, nil, false)) }
    for (index, button) in footerButtons.enumerated() {
      guard index < footer.count else {
        button.isHidden = true
        continue
      }
      let item = footer[index]
      button.isHidden = false
      button.value = item.icon
      button.set(label: item.label, symbol: item.symbol, ink: ink, text: color("textPrimary") ?? .labelColor, fill: color("urlPill"), active: hover, selected: item.selected)
    }
  }

  private func refilter(scrollToTop: Bool) {
    guard let state else { return }
    items = SidebarIconPickerMetrics.items(state, tab: tab, query: field.stringValue)
    grid.items = items
    empty.isHidden = !items.isEmpty
    if items.isEmpty {
      let m = SidebarIconPickerMetrics.self
      empty.storage.setAttributedString(NSAttributedString(string: "No matches", attributes: [.font: NSFont.systemFont(ofSize: m.label), .foregroundColor: color("textTertiary") ?? .tertiaryLabelColor]))
      emptyHeight = empty.measure(width: m.inner - 2 * m.emptyPadding).height
      empty.needsDisplay = true
    }
    layoutPanel()
    if scrollToTop { scroll.contentView.scroll(to: .zero) }
    scroll.reflectScrolledClipView(scroll.contentView)
  }

  var gridContentHeight: CGFloat {
    let m = SidebarIconPickerMetrics.self
    if items.isEmpty { return emptyHeight + 2 * m.emptyPadding }
    let rows = (items.count + m.columns - 1) / m.columns
    return CGFloat(rows) * m.cell
  }

  public var panelHeight: CGFloat {
    guard let state else { return 0 }
    let m = SidebarIconPickerMetrics.self
    var height = 2 * m.inset + m.search + m.gap + min(m.gridRows * m.cell, gridContentHeight)
    if m.showsFooter(state) { height += m.gap + m.footer }
    return height
  }

  public override func layout() {
    super.layout()
    layoutPanel()
  }

  public override func viewDidMoveToSuperview() {
    super.viewDidMoveToSuperview()
    guard superview == nil else { return }
    state = nil
    field.stringValue = ""
    grid.hovered = nil
  }

  private func layoutPanel() {
    guard let state else { return }
    let m = SidebarIconPickerMetrics.self
    let origin = m.origin(anchor: state.anchorRect, sidebarWidth: CGFloat(state.sidebarWidth))
    panel.frame = NSRect(x: origin.x, y: origin.y, width: m.width, height: panelHeight)
    PrimitiveMotion.setInstantly { surface.frame = panel.bounds }
    var y = m.inset
    let pillWidth = m.inner - 2 * (m.tabGap + m.tabWidth)
    let pillFrame = NSRect(x: m.inset, y: y, width: pillWidth, height: m.search)
    PrimitiveMotion.setInstantly { pill.frame = pillFrame }
    glass.frame = NSRect(x: pillFrame.minX + m.searchPadding, y: y + (m.search - m.glass) / 2, width: m.glass, height: m.glass)
    let fieldX = glass.frame.maxX + m.fieldGap
    let fieldHeight = field.lineHeight
    field.frame = NSRect(x: fieldX, y: y + (m.search - fieldHeight) / 2, width: max(0, pillFrame.maxX - m.searchPadding - fieldX), height: fieldHeight)
    var x = pillFrame.maxX
    for button in tabButtons {
      x += m.tabGap
      button.frame = NSRect(x: x, y: y, width: m.tabWidth, height: m.search)
      x += m.tabWidth
    }
    y += m.search + m.gap
    let gridHeight = min(m.gridRows * m.cell, gridContentHeight)
    scroll.frame = NSRect(x: m.inset, y: y, width: m.inner, height: gridHeight)
    grid.frame = NSRect(x: 0, y: 0, width: m.inner, height: gridContentHeight)
    empty.frame = NSRect(x: m.emptyPadding, y: m.emptyPadding, width: m.inner - 2 * m.emptyPadding, height: emptyHeight)
    y += gridHeight + m.gap
    let shown = footerButtons.filter { !$0.isHidden }
    guard !shown.isEmpty else { return }
    let width = (m.inner - CGFloat(shown.count - 1) * m.footerGap) / CGFloat(shown.count)
    for (index, button) in shown.enumerated() {
      button.frame = NSRect(x: m.inset + CGFloat(index) * (width + m.footerGap), y: y, width: width, height: m.footer)
    }
  }

  public func controlTextDidChange(_ obj: Notification) {
    grid.hovered = nil
    refilter(scrollToTop: true)
  }

  public func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
    switch selector {
    case #selector(NSResponder.cancelOperation(_:)):
      onEvent?(.close)
      return true
    case #selector(NSResponder.insertNewline(_:)):
      if let first = items.first { onEvent?(.choose(first)) }
      return true
    default:
      return false
    }
  }

  @objc private func scrolled() { grid.pointerMoved() }

  @objc private func devPointer(_ note: Notification) {
    guard let window, let screen = (note.object as? NSValue)?.pointValue else { return }
    grid.pointer(at: grid.convert(window.convertPoint(fromScreen: screen), from: nil))
  }

  public override func hitTest(_ point: NSPoint) -> NSView? {
    guard state != nil else { return nil }
    let local = convert(point, from: superview)
    if panel.frame.contains(local) { return super.hitTest(point) }
    return bounds.contains(local) ? self : nil
  }

  public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
  public override func mouseDown(with event: NSEvent) { pressedOutside = true }
  public override func rightMouseDown(with event: NSEvent) {}

  public override func mouseUp(with event: NSEvent) {
    guard pressedOutside else { return }
    pressedOutside = false
    if bounds.contains(convert(event.locationInWindow, from: nil)) { onEvent?(.close) }
  }

  public func describe() -> [String: Any] {
    [
      "tab": tab.rawValue, "query": field.stringValue, "items": items.count, "first": items.first ?? NSNull(),
      "panel": [panel.frame.minX, panel.frame.minY, panel.frame.width, panel.frame.height],
      "focused": isEditing,
      "footer": footerButtons.filter { !$0.isHidden }.map(\.label),
      "hovered": grid.hovered.map { grid.items.indices.contains($0) ? grid.items[$0] : "" } ?? NSNull(),
      "scrollY": scroll.contentView.bounds.minY,
    ]
  }
}

public final class IconPickerPanelView: NSView {
  public override var isFlipped: Bool { true }
  public override func mouseDown(with event: NSEvent) {}
  public override func mouseUp(with event: NSEvent) {}
}

final class IconPickerField: NSTextField {
  override init(frame: NSRect) {
    super.init(frame: frame)
    isBordered = false
    isBezeled = false
    drawsBackground = false
    focusRingType = .none
    isEditable = true
    isSelectable = true
    usesSingleLineMode = true
    cell?.isScrollable = true
    cell?.wraps = false
    lineBreakMode = .byClipping
    font = .systemFont(ofSize: SidebarIconPickerMetrics.fieldFont)
  }

  required init?(coder: NSCoder) { fatalError() }

  override func becomeFirstResponder() -> Bool {
    let became = super.becomeFirstResponder()
    if became, let editor = currentEditor() as? NSTextView { editor.insertionPointColor = textColor ?? .labelColor }
    return became
  }

  var lineHeight: CGFloat { cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: 1000, height: 1000)).height ?? 16 }

  func apply(text: NSColor, placeholder: String, placeholderColor: NSColor) {
    textColor = text
    (currentEditor() as? NSTextView)?.insertionPointColor = text
    placeholderAttributedString = NSAttributedString(string: placeholder, attributes: [.font: NSFont.systemFont(ofSize: SidebarIconPickerMetrics.fieldFont), .foregroundColor: placeholderColor])
  }
}

final class IconPickerTabButton: NSView {
  var onPress: ((SidebarIconPickerTab) -> Void)?
  let tab: SidebarIconPickerTab
  private let plate = CALayer()
  private let symbol = SymbolView()

  override var isFlipped: Bool { true }

  init(_ tab: SidebarIconPickerTab) {
    self.tab = tab
    super.init(frame: .zero)
    wantsLayer = true
    plate.actions = SurfaceLayer.noActions
    plate.cornerRadius = SidebarIconPickerMetrics.searchRadius
    plate.cornerCurve = .circular
    layer?.addSublayer(plate)
    addSubview(symbol)
    setAccessibilityElement(true)
    setAccessibilityRole(.button)
    setAccessibilityLabel(tab == .emoji ? "Emoji" : "Icons")
  }

  required init?(coder: NSCoder) { fatalError() }

  func set(selected: Bool, hover: NSColor?, icon: NSColor) {
    PrimitiveMotion.setInstantly { plate.backgroundColor = selected ? hover?.cgColor : nil }
    symbol.set(tab == .emoji ? "face.smiling" : "star.square.on.square", size: SidebarIconPickerMetrics.tabSymbol, color: icon)
  }

  override func layout() {
    super.layout()
    let box = SidebarIconPickerMetrics.tabBox
    PrimitiveMotion.setInstantly { plate.frame = bounds }
    symbol.frame = NSRect(x: (bounds.width - box) / 2, y: (bounds.height - box) / 2, width: box, height: box)
  }

  override func mouseDown(with event: NSEvent) {}

  override func mouseUp(with event: NSEvent) {
    if bounds.contains(convert(event.locationInWindow, from: nil)) { onPress?(tab) }
  }

  override func accessibilityPerformPress() -> Bool {
    onPress?(tab)
    return true
  }
}

final class IconPickerFooterButton: NSView {
  var onPress: (() -> Void)?
  var value: String?
  private(set) var label = ""
  private let plate = CALayer()
  private let symbol = SymbolView()
  private let text = OnboardingTextNSView()
  private var textSize: CGSize = .zero
  private var fill: CGColor?
  private var active: CGColor?
  private var selected = false
  private var pressed = false { didSet { if pressed != oldValue { paint() } } }

  override var isFlipped: Bool { true }

  override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
    plate.actions = SurfaceLayer.noActions
    plate.cornerRadius = SidebarIconPickerMetrics.searchRadius
    plate.cornerCurve = .circular
    layer?.addSublayer(plate)
    addSubview(symbol)
    text.manager.usesFontLeading = false
    addSubview(text)
    setAccessibilityElement(true)
    setAccessibilityRole(.button)
  }

  required init?(coder: NSCoder) { fatalError() }

  func set(label: String, symbol name: String?, ink: NSColor, text color: NSColor, fill: NSColor?, active: NSColor?, selected: Bool) {
    self.label = label
    self.fill = fill?.cgColor
    self.active = active?.cgColor
    self.selected = selected
    symbol.isHidden = name == nil
    if let name { symbol.set(name, size: SidebarIconPickerMetrics.footerSymbol, weight: .medium, color: ink) }
    text.storage.setAttributedString(NSAttributedString(string: label, attributes: [.font: NSFont.systemFont(ofSize: SidebarIconPickerMetrics.label), .foregroundColor: color]))
    textSize = text.measure(width: .greatestFiniteMagnitude)
    text.needsDisplay = true
    setAccessibilityLabel(label)
    setAccessibilitySelected(selected)
    paint()
    needsLayout = true
  }

  private func paint() {
    PrimitiveMotion.setInstantly { plate.backgroundColor = pressed || selected ? active : fill }
  }

  override func layout() {
    super.layout()
    let m = SidebarIconPickerMetrics.self
    PrimitiveMotion.setInstantly { plate.frame = bounds }
    let scale = window?.backingScaleFactor ?? 2
    let lead = symbol.isHidden ? 0 : m.footerBox + m.footerInnerGap
    let start = (bounds.width - lead - (textSize.width - 1 / scale) - 0.001) / 2
    if !symbol.isHidden {
      symbol.frame = NSRect(x: (start * scale).rounded() / scale, y: (bounds.height - m.footerBox) / 2, width: m.footerBox, height: m.footerBox)
    }
    let x = ((start + lead) * scale).rounded(.down) / scale
    let y = m.textOffset(box: bounds.height, text: textSize.height, scale: scale)
    text.frame = NSRect(x: x, y: y, width: textSize.width, height: textSize.height)
  }

  override func mouseDown(with event: NSEvent) { pressed = true }

  override func mouseDragged(with event: NSEvent) {
    pressed = bounds.contains(convert(event.locationInWindow, from: nil))
  }

  override func mouseUp(with event: NSEvent) {
    let inside = bounds.contains(convert(event.locationInWindow, from: nil))
    pressed = false
    if inside { onPress?() }
  }

  override func accessibilityPerformPress() -> Bool {
    onPress?()
    return true
  }
}

final class IconPickerGridView: NSView {
  struct Palette {
    var hover: CGColor?
    var icon: NSColor
  }

  var onChoose: ((String) -> Void)?
  var palette = Palette(hover: nil, icon: .labelColor) { didSet { needsDisplay = true; repaintCells() } }
  var current: String? { didSet { if current != oldValue { repaintCells() } } }
  var items: [String] = [] { didSet { if items != oldValue { rebuild() } } }
  var hovered: Int? { didSet { if hovered != oldValue { repaintCells() } } }
  private var cells: [IconPickerCellView] = []
  private var pressed: Int?
  private var tracking: NSTrackingArea?

  override var isFlipped: Bool { true }

  private func rebuild() {
    let m = SidebarIconPickerMetrics.self
    while cells.count < items.count {
      let cell = IconPickerCellView()
      addSubview(cell)
      cells.append(cell)
    }
    for (index, cell) in cells.enumerated() {
      guard index < items.count else {
        cell.isHidden = true
        continue
      }
      cell.isHidden = false
      cell.frame = NSRect(x: CGFloat(index % m.columns) * m.cell, y: CGFloat(index / m.columns) * m.cell, width: m.cell, height: m.cell)
      cell.set(items[index], icon: palette.icon)
    }
    repaintCells()
  }

  private func repaintCells() {
    for (index, cell) in cells.enumerated() where index < items.count {
      cell.set(items[index], icon: palette.icon)
      cell.fill = index == hovered || items[index] == current ? palette.hover : nil
    }
  }

  func index(at point: NSPoint) -> Int? {
    let m = SidebarIconPickerMetrics.self
    guard point.x >= 0, point.y >= 0, point.x < CGFloat(m.columns) * m.cell else { return nil }
    let index = Int(point.y / m.cell) * m.columns + Int(point.x / m.cell)
    return index < items.count ? index : nil
  }

  func pointer(at point: NSPoint?) {
    guard let point, let clip = enclosingScrollView?.contentView, clip.bounds.contains(clip.convert(point, from: self)) else {
      hovered = nil
      return
    }
    hovered = index(at: point)
  }

  func pointerMoved() {
    guard let window, window.isVisible else { return }
    let location = window.mouseLocationOutsideOfEventStream
    pointer(at: convert(location, from: nil))
  }

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    if let tracking { removeTrackingArea(tracking) }
    let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect], owner: self)
    addTrackingArea(area)
    tracking = area
  }

  override func mouseEntered(with event: NSEvent) { pointer(at: convert(event.locationInWindow, from: nil)) }
  override func mouseMoved(with event: NSEvent) { pointer(at: convert(event.locationInWindow, from: nil)) }
  override func mouseExited(with event: NSEvent) { hovered = nil }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    if window == nil { hovered = nil }
  }

  override func mouseDown(with event: NSEvent) { pressed = index(at: convert(event.locationInWindow, from: nil)) }

  override func mouseUp(with event: NSEvent) {
    defer { pressed = nil }
    guard let pressed, pressed == index(at: convert(event.locationInWindow, from: nil)) else { return }
    onChoose?(items[pressed])
  }
}

final class IconPickerCellView: NSView {
  private let plate = CALayer()
  private let symbol = SymbolView()
  private let emoji = OnboardingTextNSView()
  private var shown: String?
  private var emojiSize: CGSize = .zero
  var fill: CGColor? { didSet { if fill != oldValue { PrimitiveMotion.setInstantly { plate.backgroundColor = fill } } } }

  override var isFlipped: Bool { true }

  override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
    plate.actions = SurfaceLayer.noActions
    plate.cornerRadius = SidebarIconPickerMetrics.cellRadius
    plate.cornerCurve = .circular
    layer?.addSublayer(plate)
    addSubview(symbol)
    emoji.manager.usesFontLeading = false
    addSubview(emoji)
  }

  required init?(coder: NSCoder) { fatalError() }

  override func hitTest(_ point: NSPoint) -> NSView? { nil }

  func set(_ icon: String, icon color: NSColor) {
    let m = SidebarIconPickerMetrics.self
    if icon.hasPrefix(m.symbolPrefix) {
      symbol.isHidden = false
      emoji.isHidden = true
      symbol.set(String(icon.dropFirst(m.symbolPrefix.count)), size: m.cellSymbol, color: color)
      if shown != icon { setAccessibilityLabel(String(icon.dropFirst(m.symbolPrefix.count))) }
    } else {
      symbol.isHidden = true
      emoji.isHidden = false
      if shown != icon {
        emoji.storage.setAttributedString(NSAttributedString(string: icon, attributes: [.font: NSFont.systemFont(ofSize: m.emojiFont)]))
        emojiSize = emoji.measure(width: .greatestFiniteMagnitude)
        emoji.needsDisplay = true
        setAccessibilityLabel(icon)
      }
    }
    shown = icon
    needsLayout = true
  }

  override func layout() {
    super.layout()
    let m = SidebarIconPickerMetrics.self
    PrimitiveMotion.setInstantly { plate.frame = bounds }
    symbol.frame = NSRect(x: (bounds.width - m.cellBox) / 2, y: (bounds.height - m.cellBox) / 2, width: m.cellBox, height: m.cellBox)
    let x = SidebarIconPickerMetrics.textOffset(box: bounds.width, text: emojiSize.width, scale: window?.backingScaleFactor ?? 2)
    let y = SidebarIconPickerMetrics.textOffset(box: bounds.height, text: emojiSize.height, scale: window?.backingScaleFactor ?? 2)
    emoji.frame = NSRect(x: x, y: y, width: emojiSize.width, height: emojiSize.height)
  }
}
