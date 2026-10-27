import SwiftUI

struct KitGeo: Equatable {
  static let design = CGSize(width: 860, height: 600)

  let s: Double
  let W: Double
  let H: Double

  init(width: Double, height: Double) {
    s = min(width / Self.design.width, height / Self.design.height)
    W = width / s
    H = height / s
  }
}

struct KitRect {
  var x: Double
  var y: Double
  var w: Double
  var h: Double
}

enum Kit {
  static let sidebarW = 190.0
  static let rowX = 6.0, rowW = 178.0, rowH = 34.0, rowPitch = 37.0, rowTop = 62.0, rowTopWithField = 94.0
  static let field = KitRect(x: 6, y: 46, w: 178, h: 34)
  static let toolbarH = 41.0
  static let crumbX = 153.0
  static let stripH = 42.0
  static let chipX = 76.0, chipW = 173.0, chipGap = 4.0, chipTop = 5.0, chipH = 32.0
  static let lightsToolbar = 27.0, lightsField = 24.0, lightsStrip = 20.75
  static let toolbarIcons: [Double] = [21, 56, 92, 127]
  static let sidebarIcons: [Double] = [98, 133, 168]
  static let hairline = 0.5
  static let lightColors = ["#FF5F57", "#FEBC2E", "#28C840"]

  static func rowY(_ i: Int, _ top: Double = rowTop) -> Double { top + Double(i) * rowPitch }
  static func sideCard(_ g: KitGeo) -> KitRect { KitRect(x: sidebarW + 7, y: 6, w: g.W - sidebarW - 14, h: g.H - 13) }
  static func topCard(_ g: KitGeo) -> KitRect { KitRect(x: 6, y: stripH, w: g.W - 12, h: g.H - stripH - 6) }
}

struct KitTab: Equatable {
  let title: String
  let host: String
  let color: String
  let icon: String

  static let all: [KitTab] = [
    KitTab(title: "Field Notes", host: "fieldnotes.blog", color: "#4E8A5B", icon: "leaf.fill"),
    KitTab(title: "Inbox", host: "mail.fastmail.com", color: "#3A7BEA", icon: "envelope.fill"),
    KitTab(title: "Weekend in Lisbon", host: "maps.apple.com", color: "#E8664A", icon: "map.fill"),
    KitTab(title: "Q4 roadmap", host: "docs.new", color: "#7C6BD6", icon: "doc.text.fill"),
    KitTab(title: "Focus mix", host: "music.apple.com", color: "#E0457B", icon: "music.note"),
    KitTab(title: "Sourdough, day 2", host: "cooking.nytimes.com", color: "#E3A21A", icon: "fork.knife"),
    KitTab(title: "Pull requests", host: "github.com", color: "#24292F", icon: "arrow.triangle.pull"),
  ]
  static let newTab = KitTab(title: "New Tab", host: "", color: "#8E8E93", icon: "plus")
  static let blank = KitTab(title: "New Tab", host: "", color: "#A1A1A6", icon: "globe")

  static func at(_ i: Int) -> KitTab { all[i % all.count] }
}

struct PreviewArticle {
  let site: String
  let band: [String]
  let title: String
  let byline: String
  let body: String
  let sky: [String]
  let sun: [String]
  let far: [String]
  let near: [String]
  let sea: [String]

  static let notes = PreviewArticle(
    site: "Field Notes",
    band: ["#E6EEE3", "#1E2722"],
    title: "A slow morning on the coast trail",
    byline: "Mara Lindqvist · 6 min read",
    body: "We left before the fog lifted, coffee in the side pocket, and walked until the cliffs ran out. Nobody else was there, just gulls and the sound of the tide coming back in.",
    sky: ["#CFE2EC", "#2A3946"], sun: ["#F6D58C", "#CDAE63"], far: ["#A8C8A2", "#3E5A45"], near: ["#7DAA83", "#2F4839"], sea: ["#9CC3D4", "#2D4A59"]
  )

  static let trip = PreviewArticle(
    site: "Wanderlog",
    band: ["#E5ECF6", "#1C2330"],
    title: "Three days in Lisbon",
    byline: "Itinerary · 12 places · shared with 2",
    body: "Day one starts in Alfama with pastéis de nata at the corner bakery, then the 28 tram up to the castle before the crowds arrive.",
    sky: ["#F4D9C2", "#4A3439"], sun: ["#F2A86A", "#C77F4B"], far: ["#E7B9A0", "#5B4044"], near: ["#C98F7A", "#43303A"], sea: ["#B7CFE0", "#2C3E52"]
  )
}

struct KitTracker {
  static let samples = 8

  let ms: Double
  let duration: Double

  init(ms: Double, duration: Double) {
    self.ms = min(max(ms, 0), duration)
    self.duration = duration
  }

  func callAsFunction(_ stops: [(Double, Double)], _ ease: RNEasing = .outCubic) -> Double {
    var input: [Double] = []
    var output: [Double] = []
    func push(_ at: Double, _ value: Double) {
      let last = input.last ?? -Double.infinity
      input.append(max(at, last + 0.5))
      output.append(value)
    }
    for (i, stop) in stops.enumerated() {
      if i == 0 {
        push(stop.0, stop.1)
        continue
      }
      let (from, start) = stops[i - 1]
      if stop.1 == start {
        push(stop.0, stop.1)
        continue
      }
      for k in 1...Self.samples {
        let f = Double(k) / Double(Self.samples)
        push(from + (stop.0 - from) * f, start + (stop.1 - start) * ease(f))
      }
    }
    if input.count == 1 { push(input[0] + 1, output[0]) }
    return rnInterpolate(ms, input, output, clamp: true)
  }

  func fadeIn(_ at: Double, _ length: Double = 240) -> Double { self([(at, 0), (at + length, 1)]) }
  func fadeOut(_ at: Double, _ length: Double = 240) -> Double { self([(at, 1), (at + length, 0)]) }
  func step(_ at: Double, from: Double = 0, to: Double = 1) -> Double { self([(at, from), (at + 1, to)], .linear) }
}

struct KitStack: Layout {
  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    proposal.replacingUnspecifiedDimensions(by: .zero)
  }

  func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
    for subview in subviews {
      subview.place(at: bounds.origin, anchor: .topLeading, proposal: ProposedViewSize(bounds.size))
    }
  }
}

struct RNTransform: ViewModifier {
  static let none = RNTransform()

  var opacity: Double = 1
  var tx: Double = 0
  var ty: Double = 0
  var scale: Double = 1
  var sx: Double = 1
  var sy: Double = 1
  var rotate: Double = 0

  func body(content: Content) -> some View {
    content
      .scaleEffect(x: scale * sx, y: scale * sy)
      .rotationEffect(.degrees(rotate))
      .offset(x: tx, y: ty)
      .opacity(opacity)
  }
}

extension View {
  func rn(opacity: Double = 1, tx: Double = 0, ty: Double = 0, scale: Double = 1, sx: Double = 1, sy: Double = 1, rotate: Double = 0) -> some View {
    modifier(RNTransform(opacity: opacity, tx: tx, ty: ty, scale: scale, sx: sx, sy: sy, rotate: rotate))
  }

  func at(_ g: KitGeo, _ x: Double, _ y: Double, _ w: Double, _ h: Double, alignment: Alignment = .topLeading, _ fx: RNTransform = RNTransform()) -> some View {
    frame(width: max(0, w * g.s), height: max(0, h * g.s), alignment: alignment).modifier(fx).offset(x: x * g.s, y: y * g.s)
  }

  func at(_ g: KitGeo, _ r: KitRect, alignment: Alignment = .topLeading, _ fx: RNTransform = RNTransform()) -> some View { at(g, r.x, r.y, r.w, r.h, alignment: alignment, fx) }

  func fx(_ t: RNTransform) -> some View { modifier(t) }
}

struct KitSurface: View {
  let fill: String
  let radius: Double
  var border: [String] = []
  var borderWidth: Double = 0.5
  var shadow: String = "#000000"
  var shadowOpacity: Double = 0
  var shadowRadius: Double = 0
  var shadowY: Double = 0

  var body: some View {
    let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
    shape
      .fill(PreviewColor.color(fill))
      .overlay {
        if border.count > 1 {
          shape.strokeBorder(LinearGradient(colors: border.map(PreviewColor.color), startPoint: .top, endPoint: .bottom), lineWidth: borderWidth)
        } else if let color = border.first {
          shape.strokeBorder(PreviewColor.color(color), lineWidth: borderWidth)
        }
      }
      .shadow(color: shadowOpacity > 0 ? PreviewColor.color(shadow).opacity(shadowOpacity) : .clear, radius: shadowRadius, x: 0, y: shadowY)
  }
}

struct KitLabel: View {
  let g: KitGeo
  let size: Double
  let color: String
  var weight: Int = 400
  var lines = 1
  var family: String?
  var lineHeight: Double?
  let runs: [OnboardingTextRun]

  init(_ g: KitGeo, _ size: Double, _ color: String, weight: Int = 400, lines: Int = 1, family: String? = nil, lineHeight: Double? = nil, _ string: String) {
    self.init(g, size, color, weight: weight, lines: lines, family: family, lineHeight: lineHeight, runs: [OnboardingTextRun(text: string)])
  }

  init(_ g: KitGeo, _ size: Double, _ color: String, weight: Int = 400, lines: Int = 1, family: String? = nil, lineHeight: Double? = nil, runs: [OnboardingTextRun]) {
    self.g = g
    self.size = size
    self.color = color
    self.weight = weight
    self.lines = lines
    self.family = family
    self.lineHeight = lineHeight
    self.runs = runs
  }

  var body: some View {
    let layout = OnboardingTextLayout(
      runs: runs, size: size * g.s, weight: weight, color: NSColor(PreviewColor.color(color)),
      lineHeight: (lineHeight ?? size * 1.3) * g.s, kerning: 0, lines: lines, alignment: .left, family: family)
    OnboardingTextRepresentable(layout: layout)
      .accessibilityElement()
      .accessibilityLabel(layout.text)
  }
}

struct KitGlyph: View {
  let g: KitGeo
  let name: String
  let size: Double
  let color: String
  var weight: Font.Weight = .regular
  var box: Double?

  var body: some View {
    let b = (box ?? size + 4) * g.s
    Image(systemName: name)
      .font(.system(size: size * g.s, weight: weight))
      .foregroundStyle(PreviewColor.color(color))
      .frame(width: b, height: b)
  }
}

struct KitBackdrop: View {
  let look: PreviewLook

  var body: some View {
    VStack(spacing: 0) {
      ForEach(0..<10, id: \.self) { k in
        Rectangle().fill(PreviewColor.color(k == 0 ? look.tint[0] : PreviewColor.mix(look.tint[0], look.tint[1], Double(k) / 9)))
      }
    }
    .allowsHitTesting(false)
  }
}

struct KitLights: View {
  let g: KitGeo
  var y = Kit.lightsToolbar
  var x = 25.0

  var body: some View {
    KitStack {
      ForEach(0..<3, id: \.self) { i in
        Circle()
          .fill(PreviewColor.color(Kit.lightColors[i]))
          .overlay(Circle().strokeBorder(PreviewColor.color("rgba(0,0,0,0.14)"), lineWidth: Kit.hairline))
          .at(g, Double(i) * 20, 0, 12, 12)
      }
    }
    .at(g, x - 6, y - 6, 52, 12)
  }
}

struct KitFavicon: View {
  let g: KitGeo
  let tab: KitTab
  var size = 16.0

  var body: some View {
    if tab == KitTab.newTab {
      KitGlyph(g: g, name: "plus", size: size * 0.8, color: "#8E8E93", box: size)
        .frame(width: size * g.s, height: size * g.s)
    } else {
      RoundedRectangle(cornerRadius: size * 0.25 * g.s)
        .fill(PreviewColor.color(tab.color))
        .overlay(KitGlyph(g: g, name: tab.icon, size: size * 0.58, color: "#FFFFFF", weight: .semibold, box: size))
        .frame(width: size * g.s, height: size * g.s)
    }
  }
}

struct KitHighlight: View {
  let g: KitGeo
  let look: PreviewLook

  var body: some View {
    let t = look.t
    KitSurface(
      fill: t.tabSelected, radius: 10 * g.s, border: t.tabSelectedBorder, shadow: t.tabSelectedShadow, shadowOpacity: 1,
      shadowRadius: t.tabSelectedShadowRadius * g.s, shadowY: 0.5 * g.s
    )
    .allowsHitTesting(false)
  }
}

struct KitTabRow: View {
  let g: KitGeo
  let look: PreviewLook
  let tab: KitTab
  var w = Kit.rowW
  var selected = false
  var dim = false

  var body: some View {
    ZStack(alignment: .leading) {
      if selected { KitHighlight(g: g, look: look) }
      HStack(spacing: 10 * g.s) {
        KitFavicon(g: g, tab: tab)
        KitLabel(g, 13, tab == KitTab.newTab ? look.t.textSecondary : selected ? look.t.tabSelectedText : look.t.textTab, tab.title)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
      .padding(.leading, 10 * g.s)
      .padding(.trailing, 8 * g.s)
      .opacity(dim ? 0.4 : 1)
    }
    .frame(width: w * g.s, height: Kit.rowH * g.s)
  }
}

extension View {
  func row(_ g: KitGeo, x: Double = Kit.rowX, y: Double, w: Double = Kit.rowW, _ fx: RNTransform = RNTransform()) -> some View {
    frame(width: w * g.s, height: Kit.rowH * g.s, alignment: .topLeading).modifier(fx).offset(x: x * g.s, y: y * g.s)
  }
}

struct KitRows: View {
  let g: KitGeo
  let look: PreviewLook
  var from = 0
  let n: Int
  var sel: Int?
  var top = Kit.rowTop
  var newTab = true

  var body: some View {
    KitStack {
      ForEach(0..<n, id: \.self) { i in
        KitTabRow(g: g, look: look, tab: KitTab.at(from + i), selected: i == sel).row(g, y: Kit.rowY(i, top))
      }
      if newTab { KitTabRow(g: g, look: look, tab: KitTab.newTab).row(g, y: Kit.rowY(n, top)) }
    }
  }
}

struct KitNavIcons: View {
  static let toolbarNames = ["sidebar.left", "chevron.left", "chevron.right", "arrow.clockwise"]
  static let sidebarNames = ["sidebar.left", "chevron.left", "chevron.right"]
  static let pageNames = ["chevron.left", "chevron.right", "arrow.clockwise"]

  let g: KitGeo
  let color: String
  let xs: [Double]
  let y: Double
  var names = KitNavIcons.toolbarNames

  var body: some View {
    KitStack {
      ForEach(Array(xs.enumerated()), id: \.offset) { i, x in
        KitGlyph(g: g, name: i < names.count ? names[i] : "circle", size: 14, color: color, weight: .medium, box: 20)
          .at(g, x - 10, y - 10, 20, 20, alignment: .center)
      }
    }
    .allowsHitTesting(false)
  }
}

struct KitCrumb: View {
  let g: KitGeo
  let look: PreviewLook
  let tab: KitTab
  var palette: KitToolbarPalette?

  var body: some View {
    let p = palette ?? look.plain
    let host = tab.host.hasPrefix("www.") ? String(tab.host.dropFirst(4)) : tab.host
    KitLabel(g, 13, p.text, weight: 500, runs: [OnboardingTextRun(text: host), OnboardingTextRun(text: "  /  \(tab.title)", color: NSColor(PreviewColor.color(p.secondary)), weight: 400)])
      .frame(maxWidth: .infinity, alignment: .leading)
  }
}

struct KitToolbar: View {
  let g: KitGeo
  let look: PreviewLook
  let w: Double
  let tab: KitTab
  var site = false
  var crumb = true
  var icons = Kit.toolbarIcons
  var crumbX = Kit.crumbX

  var body: some View {
    let palette = site ? look.site : look.plain
    KitStack {
      if let background = palette.background { Rectangle().fill(PreviewColor.color(background)) }
      KitNavIcons(g: g, color: palette.icon, xs: icons, y: 21.2, names: icons.count == 3 ? KitNavIcons.pageNames : KitNavIcons.toolbarNames)
      if crumb { KitCrumb(g: g, look: look, tab: tab, palette: palette).at(g, crumbX, 12, w - crumbX - 20, 18) }
      if !site {
        Rectangle().fill(PreviewColor.color(palette.divider)).frame(height: Kit.hairline).frame(maxHeight: .infinity, alignment: .bottom)
      }
    }
    .frame(width: w * g.s, height: Kit.toolbarH * g.s)
  }
}

struct KitSidebarField<Content: View>: View {
  let g: KitGeo
  let look: PreviewLook
  @ViewBuilder let content: () -> Content

  var body: some View {
    content()
      .padding(.horizontal, 12 * g.s)
      .frame(width: Kit.field.w * g.s, height: Kit.field.h * g.s, alignment: .leading)
      .background(RoundedRectangle(cornerRadius: 10 * g.s).fill(PreviewColor.color(look.t.pinnedResting)))
      .clipShape(RoundedRectangle(cornerRadius: 10 * g.s))
      .offset(x: Kit.field.x * g.s, y: Kit.field.y * g.s)
  }
}

extension KitSidebarField where Content == KitCrumb {
  init(g: KitGeo, look: PreviewLook, tab: KitTab) {
    self.init(g: g, look: look) { KitCrumb(g: g, look: look, tab: tab) }
  }
}

struct KitCard<Content: View>: View {
  let g: KitGeo
  let look: PreviewLook
  let rect: KitRect
  var bg: String?
  @ViewBuilder let content: () -> Content

  var body: some View {
    let shape = RoundedRectangle(cornerRadius: 10 * g.s)
    KitStack { content() }
      .frame(width: rect.w * g.s, height: rect.h * g.s)
      .background(shape.fill(PreviewColor.color(bg ?? look.page)))
      .clipShape(shape)
      .overlay(shape.strokeBorder(PreviewColor.color(look.t.cardEdge), lineWidth: Kit.hairline))
      .offset(x: rect.x * g.s, y: rect.y * g.s)
  }
}

struct KitHero: View {
  let g: KitGeo
  let look: PreviewLook
  let a: PreviewArticle
  let height: Double

  var body: some View {
    GeometryReader { proxy in
      let w = proxy.size.width
      let h = height * g.s
      ZStack(alignment: .topLeading) {
        Rectangle().fill(PreviewColor.color(look.pick(a.sky)))
        Circle().fill(PreviewColor.color(look.pick(a.sun)))
          .frame(width: h * 0.26, height: h * 0.26)
          .offset(x: w - w * 0.18 - h * 0.26, y: h * 0.16)
        RoundedRectangle(cornerRadius: h * 0.9).fill(PreviewColor.color(look.pick(a.far)))
          .frame(width: w * 0.9, height: h * 1.4)
          .offset(x: -w * 0.2, y: h * 0.42)
        RoundedRectangle(cornerRadius: h * 0.9).fill(PreviewColor.color(look.pick(a.near)))
          .frame(width: w * 0.95, height: h * 1.4)
          .offset(x: w * 0.35, y: h * 0.52)
        Rectangle().fill(PreviewColor.color(look.pick(a.sea)))
          .frame(width: w, height: h * 0.2)
          .offset(y: h * 0.8)
      }
      .frame(width: w, height: h, alignment: .topLeading)
      .clipShape(RoundedRectangle(cornerRadius: 12 * g.s))
    }
    .frame(height: height * g.s)
  }
}

struct KitPage<Extra: View>: View {
  let g: KitGeo
  let look: PreviewLook
  var a = PreviewArticle.notes
  var top = 0.0
  @ViewBuilder let extra: () -> Extra

  var body: some View {
    GeometryReader { proxy in
      let width = proxy.size.width
      VStack(spacing: 0) {
        HStack {
          KitLabel(g, 19, look.ink, weight: 700, family: "Georgia", a.site)
          Spacer(minLength: 0)
          HStack(spacing: 18 * g.s) {
            ForEach(["Journal", "Maps", "About"], id: \.self) { KitLabel(g, 11.5, look.inkDim, $0) }
          }
        }
        .padding(.horizontal, 36 * g.s)
        .frame(width: width, height: 58 * g.s)
        .background(PreviewColor.color(look.pick(a.band)))
        VStack(alignment: .leading, spacing: 12 * g.s) {
          KitHero(g: g, look: look, a: a, height: 168)
          VStack(alignment: .leading, spacing: 4 * g.s) {
            KitLabel(g, 23, look.ink, weight: 700, lines: 2, family: "Georgia", a.title)
            KitLabel(g, 11.5, look.inkFaint, a.byline)
          }
          KitLabel(g, 12.5, look.inkDim, lines: 4, lineHeight: 19, a.body)
            .fixedSize(horizontal: false, vertical: true)
          extra()
        }
        .padding(.top, 22 * g.s)
        .frame(width: min(width * 0.84, 600 * g.s), alignment: .leading)
        Spacer(minLength: 0)
      }
      .frame(width: width, height: proxy.size.height, alignment: .top)
    }
    .background(PreviewColor.color(look.page))
    .clipped()
    .padding(.top, top * g.s)
    .allowsHitTesting(false)
  }
}

extension KitPage where Extra == EmptyView {
  init(g: KitGeo, look: PreviewLook, a: PreviewArticle = .notes, top: Double = 0) {
    self.init(g: g, look: look, a: a, top: top) { EmptyView() }
  }
}

struct KitNewTabPage: View {
  let g: KitGeo
  let look: PreviewLook
  var top = 0.0
  let width: Double

  var body: some View {
    let barW = min(520, width - 60)
    VStack(spacing: 0) {
      HStack(spacing: 9 * g.s) {
        KitGlyph(g: g, name: "magnifyingglass", size: 14, color: look.t.textSecondary, weight: .medium, box: 18)
        KitLabel(g, 15, look.t.placeholder, "Search or enter address")
        Spacer(minLength: 0)
      }
      .padding(.horizontal, 14 * g.s)
      .frame(width: barW * g.s, height: 43 * g.s)
      .background(RoundedRectangle(cornerRadius: 14 * g.s).fill(PreviewColor.color(look.t.ntpBarSolid)))
      .overlay(RoundedRectangle(cornerRadius: 14 * g.s).strokeBorder(PreviewColor.color(look.t.ntpBarBorder), lineWidth: Kit.hairline))
      .padding(.top, 120 * g.s)
      HStack(spacing: 16 * g.s) {
        ForEach(0..<6, id: \.self) { i in
          RoundedRectangle(cornerRadius: 12 * g.s)
            .fill(PreviewColor.color(look.t.pinnedResting))
            .frame(width: 46 * g.s, height: 46 * g.s)
            .overlay(KitFavicon(g: g, tab: KitTab.at(i), size: 22))
        }
      }
      .padding(.top, 30 * g.s)
      Spacer(minLength: 0)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(PreviewColor.color(look.card))
    .padding(.top, top * g.s)
    .allowsHitTesting(false)
  }
}

struct KitPanel<Content: View>: View {
  let g: KitGeo
  let look: PreviewLook
  let rect: KitRect
  var radius = 17.0
  @ViewBuilder let content: () -> Content

  var body: some View {
    ZStack(alignment: .topLeading) {
      KitSurface(fill: look.t.panel, radius: radius * g.s, border: [look.t.panelBorder], shadowOpacity: look.t.panelShadowOpacity, shadowRadius: 24 * g.s, shadowY: 10 * g.s)
      VStack(alignment: .leading, spacing: 0) { content() }
        .frame(width: rect.w * g.s, height: rect.h * g.s, alignment: .topLeading)
        .clipShape(RoundedRectangle(cornerRadius: radius * g.s, style: .continuous))
    }
    .frame(width: rect.w * g.s, height: rect.h * g.s)
  }
}

struct KitSuggestion {
  var icon: String?
  var fav: KitTab?
  let title: String
  var detail: String?
  var hint: String?
}

struct KitSuggestionRow: View {
  let g: KitGeo
  let look: PreviewLook
  let s: KitSuggestion
  var selected = false

  var body: some View {
    HStack(spacing: 10 * g.s) {
      if let fav = s.fav {
        KitFavicon(g: g, tab: fav)
      } else {
        KitGlyph(g: g, name: s.icon ?? "magnifyingglass", size: 13, color: look.t.textSecondary, weight: .medium, box: 16)
      }
      let detail = s.detail.map { [OnboardingTextRun(text: "  \($0)", color: NSColor(PreviewColor.color(look.t.textTertiary)))] } ?? []
      KitLabel(g, 14, look.t.textPrimary, runs: [OnboardingTextRun(text: s.title)] + detail)
        .frame(maxWidth: .infinity, alignment: .leading)
      if let hint = s.hint { KitLabel(g, 12, look.t.textTertiary, hint) }
    }
    .padding(.horizontal, 13 * g.s)
    .frame(height: 35 * g.s)
    .background(RoundedRectangle(cornerRadius: 11 * g.s).fill(selected ? PreviewColor.color(look.t.commandBarSelected) : .clear))
  }
}

struct KitInputRow<Content: View>: View {
  let g: KitGeo
  let look: PreviewLook
  var height = 52.0
  @ViewBuilder let content: () -> Content

  var body: some View {
    HStack(spacing: 10 * g.s) {
      KitGlyph(g: g, name: "magnifyingglass", size: 15, color: look.t.textPrimary, weight: .medium, box: 18)
      HStack(spacing: 0) { content() }.frame(maxWidth: .infinity, alignment: .leading)
    }
    .padding(.leading, 15 * g.s)
    .padding(.trailing, 12 * g.s)
    .frame(height: height * g.s)
  }
}

struct KitKeycap: View {
  let g: KitGeo
  let look: PreviewLook
  let label: String

  var body: some View {
    KitLabel(g, 14, look.t.textPrimary, weight: 600, label)
      .padding(.horizontal, 11 * g.s)
      .frame(height: 30 * g.s)
      .background(KitSurface(fill: look.t.panel, radius: 9 * g.s, border: [look.t.panelBorder], shadowOpacity: look.dark ? 0.5 : 0.16, shadowRadius: 10 * g.s, shadowY: 3 * g.s))
      .allowsHitTesting(false)
  }
}

struct KitCursor: View {
  let g: KitGeo

  var body: some View {
    ZStack(alignment: .topLeading) {
      KitGlyph(g: g, name: "cursorarrow", size: 15, color: "#FFFFFF", weight: .bold, box: 18).offset(x: 0.8 * g.s, y: 0.8 * g.s)
      KitGlyph(g: g, name: "cursorarrow", size: 15, color: "#111111", weight: .regular, box: 18)
    }
    .frame(width: 18 * g.s, height: 18 * g.s, alignment: .topLeading)
    .allowsHitTesting(false)
  }
}

struct KitPill<Content: View>: View {
  let g: KitGeo
  let look: PreviewLook
  @ViewBuilder let content: () -> Content

  var body: some View {
    HStack(spacing: 7 * g.s) { content() }
      .padding(.horizontal, 12 * g.s)
      .frame(height: 32 * g.s)
      .background(KitSurface(fill: look.t.panel, radius: 16 * g.s, border: [look.t.panelBorder], shadowOpacity: look.dark ? 0.45 : 0.14, shadowRadius: 14 * g.s, shadowY: 4 * g.s))
      .fixedSize()
      .allowsHitTesting(false)
  }
}

extension View {
  func pinned(_ alignment: Alignment, leading: Double = 0, trailing: Double = 0, top: Double = 0, bottom: Double = 0) -> some View {
    Color.clear.overlay(alignment: alignment) {
      self.padding(EdgeInsets(top: top, leading: leading, bottom: bottom, trailing: trailing))
    }
  }
}
