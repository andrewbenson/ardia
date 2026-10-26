import SwiftUI

private struct PreviewClockKey: EnvironmentKey {
  static let defaultValue: Double? = nil
}

extension EnvironmentValues {
  var onboardingPreviewClock: Double? {
    get { self[PreviewClockKey.self] }
    set { self[PreviewClockKey.self] = newValue }
  }
}

struct MockWindow: View {
  let settings: MockSettings
  let accent: String
  let focus: PreviewId?

  var body: some View {
    GeometryReader { proxy in
      if proxy.size.width > 0 && proxy.size.height > 0 {
        MockWindowFrame(width: proxy.size.width, height: proxy.size.height, settings: settings, accent: accent, focus: focus)
      }
    }
  }
}

struct MockWindowFrame: View {
  static let inset = (x: 8.0, top: 5.0, bottom: 13.0)
  static let move = (duration: 340.0, easing: RNEasing.outCubic)
  static let fade = (duration: 380.0, easing: RNEasing.outCubic)

  @Environment(\.colorScheme) private var scheme
  @Environment(\.onboardingPreviewClock) private var frozen
  let width: Double
  let height: Double
  let settings: MockSettings
  let accent: String
  let focus: PreviewId?

  @State private var lay = MotionTween(at: 0)
  @State private var addr = MotionTween(at: 0)
  @State private var site = MotionTween(at: 0)
  @State private var focusShown = MotionTween(at: 0)
  @State private var themeFade = MotionTween(at: 1)
  @State private var accentFade = MotionTween(at: 1)
  @State private var darkLayers: (below: Bool?, above: Bool) = (nil, false)
  @State private var accentLayers: (below: String?, above: String) = (nil, "")
  @State private var demo: PreviewId?
  @State private var demoStart = Date.distantPast
  @State private var badgeStart = Date.distantPast
  @State private var busyUntil = Date.distantPast
  @State private var started = false
  @State private var demoClear: Task<Void, Never>?
  @State private var wake = 0

  var dark: Bool { settings.appearance == "dark" || (settings.appearance == "auto" && scheme == .dark) }

  var body: some View {
    let _ = wake
    let paused = frozen != nil || Date() >= busyUntil
    TimelineView(.animation(minimumInterval: nil, paused: paused)) { context in
      frame(at: context.date)
    }
    .onAppear(perform: setUp)
    .onChange(of: settings.top) { _, top in run(\.lay, top ? 1 : 0, Self.move.duration, Self.move.easing) }
    .onChange(of: settings.addressInSidebar) { _, on in run(\.addr, on ? 1 : 0, Self.move.duration, Self.move.easing) }
    .onChange(of: settings.extendWebsiteColor) { _, on in run(\.site, on ? 1 : 0, Self.fade.duration, Self.fade.easing) }
    .onChange(of: dark) { _, value in
      guard value != darkLayers.above else { return }
      darkLayers = (darkLayers.above, value)
      themeFade = MotionTween(at: 0)
      run(\.themeFade, 1, Self.fade.duration, Self.fade.easing)
      if settings.appearance == "auto" { startBadge() }
    }
    .onChange(of: settings.appearance) { _, appearance in if appearance == "auto" { startBadge() } }
    .onChange(of: accent) { _, value in
      guard value != accentLayers.above else { return }
      accentLayers = (accentLayers.above, value)
      accentFade = MotionTween(at: 0)
      run(\.accentFade, 1, Self.fade.duration, Self.fade.easing)
    }
    .onChange(of: focus) { _, id in setFocus(id) }
  }

  func setUp() {
    guard !started else { return }
    started = true
    lay = MotionTween(at: settings.top ? 1 : 0)
    addr = MotionTween(at: settings.addressInSidebar ? 1 : 0)
    site = MotionTween(at: settings.extendWebsiteColor ? 1 : 0)
    darkLayers = (nil, dark)
    accentLayers = (nil, accent)
    if let focus {
      focusShown = MotionTween(at: 1)
      demo = focus
      demoStart = Date()
      keepAwake(Demo.duration(focus))
    }
    if settings.appearance == "auto" { startBadge() }
  }

  func run(_ path: WritableKeyPath<MockWindowFrame, MotionTween>, _ target: Double, _ duration: Double, _ easing: RNEasing) {
    let now = Date()
    var tween: MotionTween
    switch path {
    case \.lay: tween = lay
    case \.addr: tween = addr
    case \.site: tween = site
    case \.focusShown: tween = focusShown
    case \.themeFade: tween = themeFade
    default: tween = accentFade
    }
    tween.retarget(target, duration: duration, easing: easing, at: now)
    switch path {
    case \.lay: lay = tween
    case \.addr: addr = tween
    case \.site: site = tween
    case \.focusShown: focusShown = tween
    case \.themeFade: themeFade = tween
    default: accentFade = tween
    }
    keepAwake(duration)
  }

  func keepAwake(_ ms: Double) {
    let until = Date().addingTimeInterval(ms / 1000 + 0.05)
    if until > busyUntil { busyUntil = until }
    wake += 1
    Task { @MainActor in
      try? await Task.sleep(for: .milliseconds(Int(ms) + 80))
      wake += 1
    }
  }

  func startBadge() {
    badgeStart = Date()
    keepAwake(900)
  }

  func setFocus(_ id: PreviewId?) {
    run(\.focusShown, id == nil ? 0 : 1, 220, .outQuad)
    demoClear?.cancel()
    if let id {
      if id != demo || demoStart == .distantPast {
        demo = id
        demoStart = Date()
      }
      keepAwake(Demo.duration(id))
    } else {
      demoClear = Task { @MainActor in
        try? await Task.sleep(for: .milliseconds(240))
        guard !Task.isCancelled else { return }
        demo = nil
        demoStart = .distantPast
      }
    }
  }

  @ViewBuilder
  func frame(at date: Date) -> some View {
    let innerW = width - Self.inset.x * 2
    let innerH = height - Self.inset.top - Self.inset.bottom
    let g = KitGeo(width: innerW, height: innerH)
    let look = PreviewLook.of(dark: dark, accent: accent)
    let systemDark = scheme == .dark
    let opts = SceneOpts(addressInSidebar: settings.addressInSidebar, systemDark: systemDark, accent: accent)
    let radius = 12 * g.s
    let state = WindowStateValues(lay: lay.value(at: date), addr: addr.value(at: date), site: site.value(at: date), accentFade: accentFade.value(at: date))
    let shown = frozen != nil ? (focus == nil ? 0 : 1) : focusShown.value(at: date)
    let fade = themeFade.value(at: date)
    let demoMs = frozen ?? date.timeIntervalSince(demoStart) * 1000
    let badgeMs = frozen.map { _ in 900.0 } ?? date.timeIntervalSince(badgeStart) * 1000
    ZStack(alignment: .topLeading) {
      KitSurface(fill: look.tint[1], radius: radius, border: [dark ? "#FFFFFF2E" : "#0000002A"], shadowOpacity: dark ? 0.5 : 0.2, shadowRadius: 16, shadowY: 7)
      KitStack {
        KitStack {
          if let below = darkLayers.below, fade < 1 {
            MockWindowState(g: g, look: PreviewLook.of(dark: below, accent: accent), accent: accent, previousAccent: accentLayers.below, v: state)
          }
          MockWindowState(g: g, look: PreviewLook.of(dark: darkLayers.below != nil && fade < 1 ? darkLayers.above : dark, accent: accent), accent: accent, previousAccent: accentLayers.below, v: state)
            .opacity(darkLayers.below != nil && fade < 1 ? fade : 1)
          if settings.appearance == "auto" {
            AutoBadge(g: g, look: look, ms: badgeMs)
          }
        }
        .opacity(1 - shown)
        if let demo = frozen != nil ? focus : demo {
          DemoScene(id: demo, g: g, look: look, ms: demoMs, opts: opts).opacity(shown)
        }
      }
      .frame(width: innerW, height: innerH, alignment: .topLeading)
      .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
    .frame(width: innerW, height: innerH)
    .offset(x: Self.inset.x, y: Self.inset.top)
    .frame(width: width, height: height, alignment: .topLeading)
  }
}

struct WindowStateValues {
  var lay: Double
  var addr: Double
  var site: Double
  var accentFade: Double
}

struct AutoBadge: View {
  let g: KitGeo
  let look: PreviewLook
  let ms: Double

  var body: some View {
    let t = KitTracker(ms: ms, duration: 900)
    KitPill(g: g, look: look) {
      KitGlyph(g: g, name: look.dark ? "moon.fill" : "sun.max.fill", size: 14, color: look.dark ? "#C7CCE6" : "#E3A21A", weight: .medium, box: 18)
        .rotationEffect(.degrees(t([(60, -120), (700, 0)])))
      KitLabel(g, 13, look.t.textPrimary, weight: 500, "Auto · \(look.dark ? "Dark" : "Light") like your Mac")
    }
    .fx(RNTransform(opacity: t.fadeIn(0, 220), ty: t([(0, 6 * g.s), (300, 0)])))
    .pinned(.bottomLeading, leading: 16 * g.s, bottom: 16 * g.s)
  }
}

struct MockWindowState: View {
  let g: KitGeo
  let look: PreviewLook
  let accent: String
  let previousAccent: String?
  let v: WindowStateValues

  var body: some View {
    let s = g.s
    let lay = v.lay, addr = v.addr, site = v.site
    let lerp = { (t: Double, a: Double, b: Double) in (a + (b - a) * t) * s }
    let mix = { (t: Double, a: Double, b: Double) in a + (b - a) * t }
    let sideCardW = g.W - Kit.sidebarW - 14
    let step = Kit.chipW + Kit.chipGap
    let chips = max(1, min(4, Int(((g.W - Kit.chipX - 40) / step).rounded(.down))))
    let rows = max(1, min(6, Int(((g.H - Kit.rowTopWithField - Kit.rowPitch - 20) / Kit.rowPitch).rounded(.down))))
    let crumbLeft = lerp(lay, Kit.sidebarW + 7 + Kit.crumbX, 6 + 118) + lerp(addr, 0, Kit.field.x + 12 - (Kit.sidebarW + 7 + Kit.crumbX))
    let crumbTop = lerp(lay, 6 + 12, Kit.stripH + 12) + lerp(addr, 0, Kit.field.y + 8 - 18)
    let band = Rectangle().fill(PreviewColor.color(look.site.background ?? look.card)).opacity(site)
    KitStack {
      KitStack {
        if let previousAccent, v.accentFade < 1 { KitBackdrop(look: PreviewLook.of(dark: look.dark, accent: previousAccent)) }
        KitBackdrop(look: look).opacity(previousAccent != nil && v.accentFade < 1 ? v.accentFade : 1)
      }
      KitLights(g: g)
        .frame(width: 80 * s, height: 50 * s, alignment: .topLeading)
        .offset(x: lerp(lay, 0, 20.75 - 25), y: lerp(lay, 0, Kit.lightsStrip - Kit.lightsToolbar) + lerp(addr, 0, Kit.lightsField - Kit.lightsToolbar))
      KitStack {
        KitNavIcons(g: g, color: look.t.icon, xs: Kit.sidebarIcons, y: Kit.lightsField, names: KitNavIcons.sidebarNames).opacity(addr)
        KitRows(g: g, look: look, n: rows, sel: 0).offset(y: lerp(addr, 0, Kit.rowTopWithField - Kit.rowTop))
        RoundedRectangle(cornerRadius: 10 * s)
          .fill(PreviewColor.color(look.t.pinnedResting))
          .frame(width: lerp(addr, 320, Kit.field.w), height: Kit.field.h * s)
          .opacity(addr)
          .offset(x: crumbLeft - 12 * s, y: crumbTop - 8 * s)
      }
      .opacity(mix(lay, 1, 0))
      .offset(x: lerp(lay, 0, -60))
      KitStack {
        band.background(PreviewColor.color(look.card))
          .clipShape(UnevenRoundedRectangle(topLeadingRadius: 10 * s, topTrailingRadius: 10 * s))
          .at(g, Kit.chipX, 3, Kit.chipW, Kit.stripH - 2)
        ForEach(0..<chips, id: \.self) { i in
          KitTabRow(g: g, look: look, tab: KitTab.at(i), w: Kit.chipW).row(g, x: Kit.chipX + Double(i) * step, y: Kit.chipTop - 1, w: Kit.chipW)
        }
      }
      .opacity(lay)
      .offset(y: lerp(lay, -8, 0))
      KitStack {
        KitPage(g: g, look: look, top: Kit.toolbarH).offset(y: lerp(addr, 0, -Kit.toolbarH))
        KitStack {
          band
          KitNavIcons(g: g, color: look.plain.icon, xs: Kit.toolbarIcons, y: 21.2).opacity(mix(lay, 1, 0))
          KitNavIcons(g: g, color: look.plain.icon, xs: [21, 56, 92], y: 21.2, names: KitNavIcons.pageNames).opacity(lay)
          Rectangle().fill(PreviewColor.color(look.plain.divider)).frame(height: Kit.hairline).frame(maxHeight: .infinity, alignment: .bottom).opacity(mix(site, 1, 0))
        }
        .background(PreviewColor.color(look.card))
        .frame(height: Kit.toolbarH * s)
        .opacity(mix(addr, 1, 0))
      }
      .frame(width: lerp(lay, sideCardW, g.W - 12), height: lerp(lay, g.H - 13, g.H - Kit.stripH - 6), alignment: .topLeading)
      .background(PreviewColor.color(look.page))
      .clipShape(RoundedRectangle(cornerRadius: 10 * s))
      .overlay(RoundedRectangle(cornerRadius: 10 * s).strokeBorder(PreviewColor.color(look.t.cardEdge), lineWidth: Kit.hairline))
      .offset(x: lerp(lay, Kit.sidebarW + 7, 6), y: lerp(lay, 6, Kit.stripH))
      KitCrumb(g: g, look: look, tab: KitTab.at(0))
        .frame(width: lerp(addr, 300, Kit.field.w - 24), height: 18 * s, alignment: .leading)
        .offset(x: crumbLeft, y: crumbTop)
    }
  }
}
