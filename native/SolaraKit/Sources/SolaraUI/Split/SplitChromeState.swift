import AppKit

public struct SplitChromeTheme: Equatable, @unchecked Sendable {
  public var dark: Bool
  public var accent: NSColor
  public var textPrimary: NSColor
  public var textSecondary: NSColor
  public var icon: NSColor
  public var toolbarHover: NSColor
  public var toolbarPressed: NSColor
  public var urlPill: NSColor
  public var tokens: [String: String] = [:]

  public static let fallback = SplitChromeTheme(
    dark: false, accent: .controlAccentColor, textPrimary: .labelColor, textSecondary: .secondaryLabelColor, icon: .secondaryLabelColor,
    toolbarHover: NSColor(white: 0, alpha: 0.06), toolbarPressed: NSColor(white: 0, alpha: 0.1), urlPill: NSColor(white: 0, alpha: 0.05))

  public init(
    dark: Bool, accent: NSColor, textPrimary: NSColor, textSecondary: NSColor, icon: NSColor, toolbarHover: NSColor, toolbarPressed: NSColor,
    urlPill: NSColor
  ) {
    self.dark = dark
    self.accent = accent
    self.textPrimary = textPrimary
    self.textSecondary = textSecondary
    self.icon = icon
    self.toolbarHover = toolbarHover
    self.toolbarPressed = toolbarPressed
    self.urlPill = urlPill
  }

  public init(_ o: [String: Any]) {
    let base = Self.fallback
    func color(_ key: String, _ fallback: NSColor) -> NSColor { (o[key] as? String).flatMap { CSSColor($0)?.ns } ?? fallback }
    self.init(
      dark: o["dark"] as? Bool ?? false, accent: color("accent", base.accent), textPrimary: color("textPrimary", base.textPrimary),
      textSecondary: color("textSecondary", base.textSecondary), icon: color("icon", base.icon), toolbarHover: color("toolbarHover", base.toolbarHover),
      toolbarPressed: color("toolbarPressed", base.toolbarPressed), urlPill: color("urlPill", base.urlPill))
    tokens = o.compactMapValues { $0 as? String }
  }

  public func color(_ key: String, dark darkValue: String, light lightValue: String) -> NSColor {
    tokens[key].flatMap { CSSColor($0)?.ns } ?? CSSColor(dark ? darkValue : lightValue)?.ns ?? .labelColor
  }
}

public struct SplitDropPane: Equatable, Sendable {
  public var tabId: String
  public var rect: CGRect

  public init(tabId: String, rect: CGRect) {
    self.tabId = tabId
    self.rect = rect
  }
}

public struct SplitDragFrame: Equatable, Sendable {
  public static let version = 1

  public var shown: Bool
  public var grown: Bool
  public var px: CGFloat
  public var target: SplitDropTarget?
  public var panes: [SplitDropPane]

  public init(shown: Bool, grown: Bool, px: CGFloat, target: SplitDropTarget?, panes: [SplitDropPane]) {
    self.shown = shown
    self.grown = grown
    self.px = px
    self.target = target
    self.panes = panes
  }

  public init?(_ o: [String: Any]) {
    guard o["v"] as? Int == Self.version else { return nil }
    let target = (o["target"] as? [Any]).flatMap { pair -> SplitDropTarget? in
      guard pair.count == 2, let id = pair[0] as? String, let side = (pair[1] as? String).flatMap(SplitSide.init(rawValue:)) else { return nil }
      return SplitDropTarget(tabId: id, side: side)
    }
    let panes = (o["panes"] as? [[Any]] ?? []).compactMap { p -> SplitDropPane? in
      guard p.count == 5, let id = p[0] as? String else { return nil }
      let n = p.dropFirst().compactMap { ($0 as? NSNumber).map { CGFloat($0.doubleValue) } }
      guard n.count == 4 else { return nil }
      return SplitDropPane(tabId: id, rect: CGRect(x: n[0], y: n[1], width: n[2], height: n[3]))
    }
    self.init(
      shown: o["shown"] as? Bool ?? false, grown: o["grown"] as? Bool ?? false, px: CGFloat((o["px"] as? NSNumber)?.doubleValue ?? -1), target: target,
      panes: panes)
  }
}

public struct SplitToastSpec: Equatable, Sendable {
  public var id: Int
  public var title: String
  public var message: String?
  public var icon: String?
  public var action: String?
  public var sticky: Bool

  public init(id: Int, title: String, message: String? = nil, icon: String? = nil, action: String? = nil, sticky: Bool = false) {
    self.id = id
    self.title = title
    self.message = message
    self.icon = icon
    self.action = action
    self.sticky = sticky
  }

  public init?(_ o: [String: Any]) {
    guard let id = (o["id"] as? NSNumber)?.intValue, let title = o["title"] as? String else { return nil }
    self.init(id: id, title: title, message: o["message"] as? String, icon: o["icon"] as? String, action: o["action"] as? String, sticky: o["sticky"] as? Bool ?? false)
  }

  public var hideAfter: TimeInterval { action == nil ? 2.6 : 4 }
}
