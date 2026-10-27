import AppKit

public struct SidebarFaviconRequest: Hashable, Sendable {
  public var url: String
  public var favicon: String?
  public var profileId: String
  public var dark: Bool
}

@MainActor
public final class SidebarFavicons {
  public typealias Loader = @MainActor (SidebarFaviconRequest) async throws -> NSImage?

  public var loader: Loader?
  public var newTabMark: NSImage?
  private var cache: [SidebarFaviconRequest: NSImage] = [:]
  private var missing: Set<SidebarFaviconRequest> = []
  private var pending: [SidebarFaviconRequest: [(NSImage?) -> Void]] = [:]

  public init() {}

  public func cached(_ request: SidebarFaviconRequest) -> NSImage?? {
    if let image = cache[request] { return .some(image) }
    if missing.contains(request) { return .some(nil) }
    return nil
  }

  public func load(_ request: SidebarFaviconRequest, _ done: @escaping (NSImage?) -> Void) {
    if let known = cached(request) { return done(known) }
    if pending[request] != nil {
      pending[request]?.append(done)
      return
    }
    guard let loader else { return done(nil) }
    pending[request] = [done]
    Task { @MainActor in
      let loaded = try? await loader(request)
      let image = loaded ?? nil
      if let image { self.cache[request] = image } else if loaded != nil { self.missing.insert(request) }
      if self.cache.count > 2000 { self.cache.removeAll() }
      let waiting = self.pending.removeValue(forKey: request) ?? []
      for callback in waiting { callback(image) }
    }
  }

  public func forget(url: String) {
    for key in cache.keys where key.url == url { cache[key] = nil }
    missing = missing.filter { $0.url != url }
  }
}

struct TabIconSpec: Equatable {
  var url: String
  var favicon: String?
  var customIcon: String?
  var profileId: String
  var size: CGFloat = 16
  var dimmed = false
  var engineSymbol: String?
}

final class TabIconView: NSView {
  private let image = NSImageView()
  private let symbol = SymbolView()
  private let emoji = NSTextField(labelWithString: "")
  private let fallback = CALayer()
  private let initial = NSTextField(labelWithString: "")
  private var badge: NSView?
  private var spec: TabIconSpec?
  private var dark = true
  private var palette: SidebarPalette?
  private var requested: SidebarFaviconRequest?
  weak var favicons: SidebarFavicons?

  override var isFlipped: Bool { true }

  override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
    image.imageScaling = .scaleProportionallyUpOrDown
    image.wantsLayer = true
    for v in [image, symbol, emoji, initial] as [NSView] {
      v.isHidden = true
      addSubview(v)
    }
    emoji.alignment = .center
    initial.alignment = .center
    fallback.cornerCurve = .continuous
    fallback.actions = SurfaceLayer.noActions
    layer?.insertSublayer(fallback, at: 0)
  }

  required init?(coder: NSCoder) { fatalError() }

  override func hitTest(_ point: NSPoint) -> NSView? { nil }

  func set(_ spec: TabIconSpec, palette: SidebarPalette) {
    let same = spec == self.spec && palette.dark == dark && self.palette != nil
    self.spec = spec
    self.palette = palette
    dark = palette.dark
    alphaValue = spec.dimmed ? 0.45 : 1
    guard !same else { return }
    render()
  }

  override func layout() {
    super.layout()
    render()
  }

  private func render() {
    guard let spec, let palette else { return }
    let size = spec.size
    let box = NSRect(x: 0, y: 0, width: size, height: size)
    for v in [image, symbol, emoji, initial] as [NSView] { v.isHidden = true }
    fallback.isHidden = true
    if let icon = spec.customIcon, icon.hasPrefix("symbol:") {
      let name = String(icon.dropFirst("symbol:".count))
      let ink = icon == "symbol:square.stack.fill" ? palette.noGroupIcon : palette.icon
      symbol.frame = box
      symbol.set(name, size: size - 3, weight: .medium, color: ink)
      symbol.isHidden = false
    } else if let icon = spec.customIcon, !icon.isEmpty {
      emoji.font = .systemFont(ofSize: size - 3)
      emoji.stringValue = icon
      let fitting = emoji.fittingSize
      emoji.frame = NSRect(x: (size - fitting.width) / 2, y: (size - fitting.height) / 2, width: fitting.width, height: fitting.height)
      emoji.isHidden = false
    } else if spec.url.isEmpty && (spec.favicon ?? "").isEmpty {
      image.frame = box
      image.image = favicons?.newTabMark
      image.contentTintColor = dark ? .white : .black
      image.alphaValue = dark ? 0.28 : 0.3
      image.layer?.cornerRadius = 0
      image.isHidden = false
    } else {
      showFavicon(spec, box: box)
    }
    renderBadge(spec, palette: palette)
  }

  private func showFavicon(_ spec: TabIconSpec, box: NSRect) {
    let request = SidebarFaviconRequest(url: spec.url, favicon: spec.favicon, profileId: spec.profileId, dark: dark)
    image.frame = box
    image.contentTintColor = nil
    image.alphaValue = 1
    image.layer?.cornerRadius = spec.size > 18 ? 4 : 3
    image.layer?.masksToBounds = true
    if let known = favicons?.cached(request) {
      if let picture = known {
        image.image = picture
        image.isHidden = false
      } else {
        showFallback(spec)
      }
      return
    }
    showFallback(spec)
    requested = request
    favicons?.load(request) { [weak self] picture in
      guard let self, picture != nil, self.requested == request else { return }
      self.render()
    }
  }

  private func showFallback(_ spec: TabIconSpec) {
    guard let palette else { return }
    let size = spec.size
    let letter = Self.hostInitial(spec.url)
    if letter.isEmpty {
      symbol.frame = NSRect(x: 0, y: 0, width: size, height: size)
      symbol.set("globe", size: size - 3, color: palette.textSecondary)
      symbol.isHidden = false
      return
    }
    let tile = (size * 14 / 16).rounded()
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    fallback.frame = CGRect(x: (size - tile) / 2, y: (size - tile) / 2, width: tile, height: tile)
    fallback.cornerRadius = tile * 0.32
    fallback.backgroundColor = (dark ? NSColor(srgbRed: 247 / 255, green: 245 / 255, blue: 1, alpha: 0.2) : NSColor(white: 0, alpha: 0.13)).cgColor
    fallback.isHidden = false
    CATransaction.commit()
    initial.font = .systemFont(ofSize: (tile * 0.64).rounded(), weight: .semibold)
    initial.textColor = palette.textSecondary
    initial.stringValue = letter
    let fitting = initial.fittingSize
    initial.frame = NSRect(x: (size - fitting.width) / 2, y: (size - fitting.height) / 2, width: fitting.width, height: fitting.height)
    initial.isHidden = false
  }

  private func renderBadge(_ spec: TabIconSpec, palette: SidebarPalette) {
    guard let name = spec.engineSymbol, spec.size >= 14 else {
      badge?.removeFromSuperview()
      badge = nil
      return
    }
    let box = (spec.size * 0.6).rounded()
    let holder = badge ?? NSView()
    holder.wantsLayer = true
    holder.layer?.cornerRadius = box / 2
    holder.layer?.backgroundColor = (palette.dark ? NSColor(srgbRed: 0x2C / 255, green: 0x2C / 255, blue: 0x2E / 255, alpha: 1) : .white).cgColor
    holder.frame = NSRect(x: spec.size - box + box / 3, y: spec.size - box + box / 3, width: box, height: box)
    let mark = (holder.subviews.first as? SymbolView) ?? SymbolView()
    if mark.superview == nil { holder.addSubview(mark) }
    mark.frame = holder.bounds
    mark.set(name, size: box - 3, weight: .semibold, color: palette.icon)
    if holder.superview == nil { addSubview(holder) }
    badge = holder
  }

  static func hostInitial(_ url: String) -> String {
    guard let match = url.range(of: #"^(?:https?|ftp)://(?:[^@/?#]*@)?([^/?#:]+)"#, options: [.regularExpression, .caseInsensitive]) else { return "" }
    var host = String(url[match])
    if let scheme = host.range(of: "://") { host = String(host[scheme.upperBound...]) }
    if let at = host.lastIndex(of: "@") { host = String(host[host.index(after: at)...]) }
    host = host.lowercased()
    if host.range(of: #"^[\d.]+$"#, options: .regularExpression) != nil || host.hasPrefix("[") { return "" }
    if host.hasPrefix("www.") { host.removeFirst(4) }
    return host.first.map { String($0).uppercased() } ?? ""
  }
}
