import SwiftUI

struct SceneOpts: Equatable {
  var addressInSidebar: Bool
  var systemDark: Bool
  var accent: String
}

extension RNTransform {
  static func + (a: RNTransform, b: RNTransform) -> RNTransform {
    RNTransform(opacity: a.opacity * b.opacity, tx: a.tx + b.tx, ty: a.ty + b.ty, scale: a.scale * b.scale, sx: a.sx * b.sx, sy: a.sy * b.sy, rotate: a.rotate + b.rotate)
  }
}

enum Demo {
  static func duration(_ id: PreviewId) -> Double {
    switch id {
    case .tabsSidebar, .tabsTop, .cmdlField, .cmdlCentred, .appearanceAuto, .appearanceLight, .appearanceDark: 1200
    case .addressToolbar, .addressSidebar, .newtabposBottom, .newtabposTop: 1100
    case .newtabPage, .newtabCommandbar, .sitecolorOn, .sitecolorOff, .typedWebsite, .typedSearch, .blockOn, .blockOff: 1300
    case .tidyKeep, .tidyAuto, .quitRestore, .quitFresh, .linksLittle, .linksTab: 1500
    case .windowsSeparate, .windowsShared: 1400
    }
  }

  static let panelH = 52.0 + 3 * 35 + 14
  static let miniSide = 150.0

  static func listTop(_ opts: SceneOpts) -> Double { opts.addressInSidebar ? Kit.rowTopWithField : Kit.rowTop }

  static func centredFrame(_ g: KitGeo) -> KitRect {
    let c = Kit.sideCard(g)
    let content = c.w < 708 ? (c.w <= 636 ? c.w - 20 : 616) : 652
    let w = min(content, c.w - 28, 560)
    return KitRect(x: c.x + (c.w - w) / 2, y: c.y + max(12, PreviewColor.jsRound(c.h * 0.22)), w: w, h: panelH)
  }

  static func grow(_ t: KitTracker, _ g: KitGeo, _ from: KitRect, _ to: KitRect, _ ms: Double, _ dur: Double = 260) -> RNTransform {
    let sx = from.w / to.w
    let sy = from.h / to.h
    return RNTransform(
      opacity: t([(ms, 0.4), (ms + 90, 1)]),
      tx: t([(ms, (from.x - to.x - (to.w * (1 - sx)) / 2) * g.s), (ms + dur, 0)]),
      ty: t([(ms, (from.y - to.y - (to.h * (1 - sy)) / 2) * g.s), (ms + dur, 0)]),
      sx: t([(ms, sx), (ms + dur, 1)]),
      sy: t([(ms, sy), (ms + dur, 1)])
    )
  }

  static func drop(_ t: KitTracker, _ g: KitGeo, _ ms: Double) -> RNTransform {
    RNTransform(opacity: t.fadeIn(ms, 200), ty: t([(ms, -10 * g.s), (ms + 300, 0)]), scale: t([(ms, 0.97), (ms + 300, 1)]))
  }

  static let current: [KitSuggestion] = [
    KitSuggestion(fav: KitTab.at(0), title: "A slow morning on the coast trail", detail: "fieldnotes.blog"),
    KitSuggestion(fav: KitTab.at(2), title: "Weekend in Lisbon", hint: "Switch to Tab"),
    KitSuggestion(icon: "magnifyingglass", title: "coast trail walks"),
  ]

  static let fresh: [KitSuggestion] = [
    KitSuggestion(fav: KitTab.at(1), title: "Inbox", hint: "Switch to Tab"),
    KitSuggestion(fav: KitTab.at(3), title: "Q4 roadmap", detail: "docs.new"),
    KitSuggestion(icon: "clock", title: "coast trail walks"),
  ]

  static let desktopLight = ["#D9DCE4", "#C4C9D6"]
  static let desktopDark = ["#1C1D22", "#2B2D35"]
  static let typeAt = 180.0
  static let typeStep = 75.0
  static let typedText = "github"
  static var typedDone: Double { typeAt + Double(typedText.count) * typeStep }
}

struct DemoScene: View {
  let id: PreviewId
  let g: KitGeo
  let look: PreviewLook
  let ms: Double
  let opts: SceneOpts

  var t: KitTracker { KitTracker(ms: ms, duration: Demo.duration(id)) }

  var body: some View {
    KitStack {
      switch id {
      case .tabsSidebar: TabsSidebarScene(g: g, look: look, t: t, opts: opts)
      case .tabsTop: TabsTopScene(g: g, look: look, t: t)
      case .addressToolbar: AddressMoveScene(g: g, look: look, t: t, toSidebar: false)
      case .addressSidebar: AddressMoveScene(g: g, look: look, t: t, toSidebar: true)
      case .cmdlField: CmdlFieldScene(g: g, look: look, t: t, opts: opts)
      case .cmdlCentred: CmdlCentredScene(g: g, look: look, t: t, opts: opts)
      case .newtabPage: NewTabOpensPageScene(g: g, look: look, t: t, opts: opts)
      case .newtabCommandbar: NewTabOpensBarScene(g: g, look: look, t: t, opts: opts)
      case .newtabposBottom: NewTabAtScene(g: g, look: look, t: t, opts: opts, top: false)
      case .newtabposTop: NewTabAtScene(g: g, look: look, t: t, opts: opts, top: true)
      case .tidyKeep: TidyScene(g: g, look: look, t: t, opts: opts, auto: false)
      case .tidyAuto: TidyScene(g: g, look: look, t: t, opts: opts, auto: true)
      case .quitRestore: QuitScene(g: g, look: look, t: t, opts: opts, fresh: false)
      case .quitFresh: QuitScene(g: g, look: look, t: t, opts: opts, fresh: true)
      case .windowsSeparate: WindowsScene(g: g, look: look, t: t, shared: false)
      case .windowsShared: WindowsScene(g: g, look: look, t: t, shared: true)
      case .appearanceAuto: AppearanceScene(g: g, t: t, opts: opts, mode: "auto")
      case .appearanceLight: AppearanceScene(g: g, t: t, opts: opts, mode: "light")
      case .appearanceDark: AppearanceScene(g: g, t: t, opts: opts, mode: "dark")
      case .sitecolorOn: SiteColorScene(g: g, look: look, t: t, opts: opts, on: true)
      case .sitecolorOff: SiteColorScene(g: g, look: look, t: t, opts: opts, on: false)
      case .typedWebsite: TypedScene(g: g, look: look, t: t, opts: opts, search: false)
      case .typedSearch: TypedScene(g: g, look: look, t: t, opts: opts, search: true)
      case .blockOn: BlockScene(g: g, look: look, t: t, opts: opts, on: true)
      case .blockOff: BlockScene(g: g, look: look, t: t, opts: opts, on: false)
      case .linksLittle: LinksScene(g: g, look: look, t: t, little: true)
      case .linksTab: LinksScene(g: g, look: look, t: t, little: false)
      }
    }
    .frame(width: g.W * g.s, height: g.H * g.s, alignment: .topLeading)
    .clipped()
  }
}

struct SceneChrome: View {
  let g: KitGeo
  let look: PreviewLook
  let opts: SceneOpts
  var sel = 0

  var body: some View {
    KitStack {
      KitBackdrop(look: look)
      KitLights(g: g, y: opts.addressInSidebar ? Kit.lightsField : Kit.lightsToolbar)
      if opts.addressInSidebar {
        KitNavIcons(g: g, color: look.t.icon, xs: Kit.sidebarIcons, y: Kit.lightsField, names: KitNavIcons.sidebarNames)
        KitSidebarField(g: g, look: look, tab: KitTab.at(sel))
      }
    }
  }
}

struct StdScene: View {
  let g: KitGeo
  let look: PreviewLook
  let opts: SceneOpts
  var n = 4
  var sel = 0
  var rows: AnyView?
  var page: AnyView?
  var card: AnyView?
  var a = PreviewArticle.notes
  var site = false

  var body: some View {
    let c = Kit.sideCard(g)
    let field = opts.addressInSidebar
    KitStack {
      SceneChrome(g: g, look: look, opts: opts, sel: sel)
      if let rows { rows } else { KitRows(g: g, look: look, n: n, sel: sel, top: Demo.listTop(opts)) }
      KitCard(g: g, look: look, rect: c) {
        if !field { KitToolbar(g: g, look: look, w: c.w, tab: KitTab.at(sel), site: site) }
        if let page { page } else { KitPage(g: g, look: look, a: a, top: field ? 0 : Kit.toolbarH) }
        if let card { card }
      }
    }
  }
}

struct KeyPress: View {
  let g: KitGeo
  let look: PreviewLook
  let t: KitTracker
  let label: String
  var ms = 0.0

  var body: some View {
    KitKeycap(g: g, look: look, label: label)
      .fx(RNTransform(opacity: t.fadeIn(ms, 160), scale: t([(ms, 0.82), (ms + 260, 1)])))
      .pinned(.topTrailing, trailing: 22 * g.s, top: (g.H - 50) * g.s)
  }
}

struct SuggestionList: View {
  let g: KitGeo
  let look: PreviewLook
  let t: KitTracker
  let rows: [KitSuggestion]
  let ms: Double

  var body: some View {
    VStack(spacing: 0) {
      ForEach(Array(rows.enumerated()), id: \.offset) { i, s in
        let at = ms + Double(i) * 50
        KitSuggestionRow(g: g, look: look, s: s, selected: i == 0)
          .fx(RNTransform(opacity: t.fadeIn(at, 200), ty: t([(at, -3 * g.s), (at + 220, 0)])))
      }
    }
    .padding(.horizontal, 9 * g.s)
    .padding(.top, 4 * g.s)
  }
}

struct SelectedUrl: View {
  let g: KitGeo
  let look: PreviewLook

  var body: some View {
    KitLabel(g, 14, look.t.textPrimary, "fieldnotes.blog/coast-trail")
      .padding(.horizontal, 1 * g.s)
      .background(RoundedRectangle(cornerRadius: 2 * g.s).fill(PreviewColor.color(look.t.selection)))
  }
}

struct KitDivider: View {
  let g: KitGeo
  let look: PreviewLook

  var body: some View {
    Rectangle().fill(PreviewColor.color(look.t.divider)).frame(height: Kit.hairline).padding(.horizontal, 14 * g.s)
  }
}

struct SwapCrumb: View {
  let g: KitGeo
  let look: PreviewLook
  let t: KitTracker
  let a: KitTab
  let b: KitTab
  let ms: Double
  let x: Double
  let y: Double

  var body: some View {
    KitStack {
      KitCrumb(g: g, look: look, tab: a).at(g, x, y, 420, 18, RNTransform(opacity: t.fadeOut(ms, 180)))
      KitCrumb(g: g, look: look, tab: b).at(g, x, y, 420, 18, RNTransform(opacity: t.fadeIn(ms + 60, 220)))
    }
  }
}

struct TwoPages: View {
  let g: KitGeo
  let look: PreviewLook
  let t: KitTracker
  let top: Double
  var outAt = 660.0
  var outLength = 200.0
  var inAt = 700.0
  var inLength = 280.0
  var first = PreviewArticle.notes
  var second = PreviewArticle.trip

  var body: some View {
    KitStack {
      KitPage(g: g, look: look, a: first, top: top).opacity(t.fadeOut(outAt, outLength))
      KitPage(g: g, look: look, a: second, top: top).opacity(t.fadeIn(inAt, inLength))
    }
  }
}

struct TabsSidebarScene: View {
  let g: KitGeo
  let look: PreviewLook
  let t: KitTracker
  let opts: SceneOpts

  var body: some View {
    let c = Kit.sideCard(g)
    let top = Demo.listTop(opts)
    let field = opts.addressInSidebar
    KitStack {
      KitBackdrop(look: look)
      KitLights(g: g, y: field ? Kit.lightsField : Kit.lightsToolbar)
      if field {
        KitNavIcons(g: g, color: look.t.icon, xs: Kit.sidebarIcons, y: Kit.lightsField, names: KitNavIcons.sidebarNames)
        KitSidebarField(g: g, look: look) { Color.clear }
        SwapCrumb(g: g, look: look, t: t, a: KitTab.at(0), b: KitTab.at(2), ms: 660, x: Kit.field.x + 12, y: Kit.field.y + 8)
      }
      KitHighlight(g: g, look: look).row(g, y: Kit.rowY(0, top), RNTransform(opacity: t.fadeIn(240, 200), ty: t([(620, 0), (900, 2 * Kit.rowPitch * g.s)])))
      ForEach(0..<5, id: \.self) { i in
        let at = Double(i) * 70
        KitTabRow(g: g, look: look, tab: i == 4 ? KitTab.newTab : KitTab.at(i))
          .row(g, y: Kit.rowY(i, top), RNTransform(opacity: t.fadeIn(at, 280), tx: t([(at, -14 * g.s), (at + 320, 0)])))
      }
      KitCard(g: g, look: look, rect: c) {
        if !field {
          KitToolbar(g: g, look: look, w: c.w, tab: KitTab.at(0), crumb: false)
          SwapCrumb(g: g, look: look, t: t, a: KitTab.at(0), b: KitTab.at(2), ms: 660, x: Kit.crumbX, y: 12)
        }
        TwoPages(g: g, look: look, t: t, top: field ? 0 : Kit.toolbarH)
      }
    }
  }
}

struct TabsTopScene: View {
  let g: KitGeo
  let look: PreviewLook
  let t: KitTracker

  var body: some View {
    let c = Kit.topCard(g)
    let step = Kit.chipW + Kit.chipGap
    KitStack {
      KitBackdrop(look: look)
      KitLights(g: g, y: Kit.lightsStrip, x: 20.75)
      KitCard(g: g, look: look, rect: c) {
        KitToolbar(g: g, look: look, w: c.w, tab: KitTab.at(0), crumb: false, icons: [21, 56, 92])
        SwapCrumb(g: g, look: look, t: t, a: KitTab.at(0), b: KitTab.at(2), ms: 660, x: 118, y: 12)
        TwoPages(g: g, look: look, t: t, top: Kit.toolbarH)
      }
      UnevenRoundedRectangle(topLeadingRadius: 10 * g.s, topTrailingRadius: 10 * g.s)
        .fill(PreviewColor.color(look.card))
        .at(g, Kit.chipX, 3, Kit.chipW, Kit.stripH - 3 + 1, RNTransform(opacity: t.fadeIn(240, 200), tx: t([(620, 0), (900, 2 * step * g.s)])))
      ForEach(0..<4, id: \.self) { i in
        let at = Double(i) * 70
        KitTabRow(g: g, look: look, tab: KitTab.at(i), w: Kit.chipW)
          .row(g, x: Kit.chipX + Double(i) * step, y: Kit.chipTop - 1, w: Kit.chipW, RNTransform(opacity: t.fadeIn(at, 280), ty: t([(at, -8 * g.s), (at + 320, 0)])))
      }
    }
  }
}

struct AddressMoveScene: View {
  let g: KitGeo
  let look: PreviewLook
  let t: KitTracker
  let toSidebar: Bool

  var body: some View {
    let c = Kit.sideCard(g)
    let m = toSidebar ? t([(220, 0), (620, 1)]) : t([(220, 1), (620, 0)])
    let lerp = { (a: Double, b: Double) in a + (b - a) * m }
    let bar = KitRect(x: c.x + Kit.crumbX - 12, y: c.y + 3.5, w: 320, h: Kit.field.h)
    let dx = bar.x - Kit.field.x
    let dy = bar.y - Kit.field.y
    KitStack {
      KitBackdrop(look: look)
      KitLights(g: g).fx(RNTransform(ty: lerp(0, (Kit.lightsField - Kit.lightsToolbar) * g.s)))
      KitNavIcons(g: g, color: look.t.icon, xs: Kit.sidebarIcons, y: Kit.lightsField, names: KitNavIcons.sidebarNames).opacity(lerp(0, 1))
      KitRows(g: g, look: look, n: 4, sel: 0).fx(RNTransform(ty: lerp(0, (Kit.rowTopWithField - Kit.rowTop) * g.s)))
      KitCard(g: g, look: look, rect: c) {
        KitToolbar(g: g, look: look, w: c.w, tab: KitTab.at(0), crumb: false).opacity(lerp(1, 0))
        KitPage(g: g, look: look, top: Kit.toolbarH).fx(RNTransform(ty: lerp(0, -Kit.toolbarH * g.s)))
      }
      RoundedRectangle(cornerRadius: 10 * g.s)
        .fill(PreviewColor.color(look.t.pinnedResting))
        .at(g, Kit.field, RNTransform(opacity: lerp(0, 1), tx: lerp((dx + (bar.w - Kit.field.w) / 2) * g.s, 0), ty: lerp(dy * g.s, 0), sx: lerp(bar.w / Kit.field.w, 1)))
      ForEach(0..<2, id: \.self) { i in
        let w = i == 0 ? 300 : Kit.field.w - 24
        let opacity = rnInterpolate(m, [0, 0.45, 0.55, 1], i == 1 ? [0, 0, 1, 1] : [1, 1, 0, 0])
        KitCrumb(g: g, look: look, tab: KitTab.at(0))
          .at(g, Kit.field.x + 12, Kit.field.y + 8, w, 18, RNTransform(
            opacity: opacity,
            tx: lerp((c.x + Kit.crumbX - Kit.field.x - 12) * g.s, 0),
            ty: lerp((c.y + 12 - Kit.field.y - 8) * g.s, 0)
          ))
      }
    }
  }
}

struct CommandPanel: View {
  let g: KitGeo
  let look: PreviewLook
  let t: KitTracker
  let rect: KitRect
  var radius = 17.0
  var inputHeight = 52.0
  let fx: RNTransform
  var rows = Demo.current

  var body: some View {
    KitPanel(g: g, look: look, rect: rect, radius: radius) {
      KitInputRow(g: g, look: look, height: inputHeight) { SelectedUrl(g: g, look: look) }
      KitDivider(g: g, look: look)
      SuggestionList(g: g, look: look, t: t, rows: rows, ms: 400)
    }
    .at(g, rect, fx)
  }
}

struct CmdlFieldScene: View {
  let g: KitGeo
  let look: PreviewLook
  let t: KitTracker
  let opts: SceneOpts

  var body: some View {
    let c = Kit.sideCard(g)
    KitStack {
      StdScene(g: g, look: look, opts: opts)
      if opts.addressInSidebar {
        let to = KitRect(x: Kit.field.x, y: Kit.field.y, w: Kit.field.w + 137, h: 40 + 3 * 35 + 14)
        CommandPanel(g: g, look: look, t: t, rect: to, radius: 12, inputHeight: 40, fx: Demo.grow(t, g, Kit.field, to, 240))
      } else {
        let from = KitRect(x: c.x + Kit.crumbX - 8, y: c.y + 6, w: 300, h: 30)
        let to = KitRect(x: c.x + Kit.crumbX - 40, y: c.y + 0.5, w: min(480, c.w - Kit.crumbX + 28), h: Demo.panelH)
        CommandPanel(g: g, look: look, t: t, rect: to, fx: Demo.grow(t, g, from, to, 240))
      }
      KeyPress(g: g, look: look, t: t, label: "⌘L")
    }
  }
}

struct CmdlCentredScene: View {
  let g: KitGeo
  let look: PreviewLook
  let t: KitTracker
  let opts: SceneOpts

  var body: some View {
    KitStack {
      StdScene(g: g, look: look, opts: opts)
      CommandPanel(g: g, look: look, t: t, rect: Demo.centredFrame(g), fx: Demo.drop(t, g, 240))
      KeyPress(g: g, look: look, t: t, label: "⌘L")
    }
  }
}

struct NewTabOpensPageScene: View {
  let g: KitGeo
  let look: PreviewLook
  let t: KitTracker
  let opts: SceneOpts

  var body: some View {
    let c = Kit.sideCard(g)
    let top = Demo.listTop(opts)
    StdScene(
      g: g, look: look, opts: opts,
      rows: AnyView(KitStack {
        KitHighlight(g: g, look: look).row(g, y: Kit.rowY(0, top), RNTransform(opacity: t.fadeOut(360, 200)))
        KitRows(g: g, look: look, n: 4, top: top, newTab: false)
        KitTabRow(g: g, look: look, tab: KitTab.blank, selected: true).row(g, y: Kit.rowY(4, top), RNTransform(opacity: t.fadeIn(300, 240), tx: t([(300, -12 * g.s), (600, 0)])))
        KitTabRow(g: g, look: look, tab: KitTab.newTab).row(g, y: Kit.rowY(4, top), RNTransform(ty: t([(300, 0), (600, Kit.rowPitch * g.s)])))
        KeyPress(g: g, look: look, t: t, label: "⌘T")
      }),
      card: AnyView(KitNewTabPage(g: g, look: look, width: c.w).opacity(t.fadeIn(420, 300)))
    )
  }
}

struct TypedText: View {
  let g: KitGeo
  let look: PreviewLook
  let t: KitTracker
  let text: String
  let at: Double
  let step: Double
  let caretUntil: Double

  func caret(_ from: Double, _ to: Double) -> Double { t([(from, 0), (from + 1, 1), (to, 1), (to + 1, 0)], .linear) }

  var bar: some View {
    RoundedRectangle(cornerRadius: 0.6 * g.s).fill(PreviewColor.color(look.t.accent)).frame(width: 1.2 * g.s, height: 17 * g.s)
  }

  var body: some View {
    let chars = Array(text)
    HStack(spacing: 0) {
      ForEach(chars.indices, id: \.self) { i in
        let start = at + Double(i) * step
        KitLabel(g, 15, look.t.textPrimary, String(chars[i]))
          .overlay(alignment: .topTrailing) {
            bar.offset(x: 1.4 * g.s, y: 1 * g.s).opacity(caret(start, i == chars.count - 1 ? caretUntil : at + Double(i + 1) * step))
          }
          .opacity(t.step(start))
      }
    }
    .overlay(alignment: .leading) { bar.opacity(caret(-1, at)) }
  }
}

struct NewTabOpensBarScene: View {
  let g: KitGeo
  let look: PreviewLook
  let t: KitTracker
  let opts: SceneOpts

  var body: some View {
    let rect = Demo.centredFrame(g)
    KitStack {
      StdScene(g: g, look: look, opts: opts)
      KitPanel(g: g, look: look, rect: rect) {
        KitInputRow(g: g, look: look) {
          RoundedRectangle(cornerRadius: 0.6 * g.s).fill(PreviewColor.color(look.t.accent)).frame(width: 1.2 * g.s, height: 17 * g.s).padding(.trailing, 2 * g.s)
          KitLabel(g, 15, look.t.placeholder, "Search or enter address")
        }
        KitDivider(g: g, look: look)
        SuggestionList(g: g, look: look, t: t, rows: Demo.fresh, ms: 400)
      }
      .at(g, rect, Demo.drop(t, g, 240))
      KeyPress(g: g, look: look, t: t, label: "⌘T")
    }
  }
}

struct NewTabAtScene: View {
  let g: KitGeo
  let look: PreviewLook
  let t: KitTracker
  let opts: SceneOpts
  let top: Bool

  var body: some View {
    let list = Demo.listTop(opts)
    let shift = RNTransform(ty: t([(200, 0), (520, Kit.rowPitch * g.s)]))
    let arrive = top
      ? RNTransform(opacity: t.fadeIn(320, 240), tx: t([(320, -12 * g.s), (620, 0)]))
      : RNTransform(opacity: t.fadeIn(220, 240), ty: t([(220, -8 * g.s), (520, 0)]), scale: t([(220, 0.96), (520, 1)]))
    StdScene(
      g: g, look: look, opts: opts,
      rows: AnyView(KitStack {
        KitStack {
          KitHighlight(g: g, look: look).row(g, y: Kit.rowY(0, list), RNTransform(opacity: t.fadeOut(280, 220)))
          KitRows(g: g, look: look, n: 4, top: list, newTab: false)
        }
        .fx(top ? shift : .none)
        KitTabRow(g: g, look: look, tab: KitTab.blank, selected: true).row(g, y: Kit.rowY(top ? 0 : 4, list), arrive)
        KitTabRow(g: g, look: look, tab: KitTab.newTab).row(g, y: Kit.rowY(4, list), shift)
      })
    )
  }
}

struct TidyScene: View {
  let g: KitGeo
  let look: PreviewLook
  let t: KitTracker
  let opts: SceneOpts
  let auto: Bool

  var body: some View {
    let c = Kit.sideCard(g)
    let list = Demo.listTop(opts)
    let old: Set<Int> = [1, 3, 4]
    let gone = auto
      ? RNTransform(opacity: t([(850, 1), (1000, 0.4), (1060, 0.4), (1300, 0)]), tx: t([(1060, 0), (1300, -10 * g.s)]), sy: t([(1060, 1), (1300, 0.6)]))
      : RNTransform.none
    let rise = { (n: Int) in auto && n > 0 ? RNTransform(ty: t([(1140, 0), (1460, -Double(n) * Kit.rowPitch * g.s)])) : RNTransform.none }
    let above = { (i: Int) in old.filter { $0 < i }.count }
    StdScene(
      g: g, look: look, opts: opts,
      rows: AnyView(KitStack {
        ForEach(0..<6, id: \.self) { i in
          KitTabRow(g: g, look: look, tab: KitTab.at(i), selected: i == 0).row(g, y: Kit.rowY(i, list), old.contains(i) ? gone : rise(above(i)))
        }
        KitTabRow(g: g, look: look, tab: KitTab.newTab).row(g, y: Kit.rowY(6, list), rise(3))
        KitPill(g: g, look: look) {
          KitGlyph(g: g, name: "clock", size: 13, color: look.t.textPrimary, weight: .medium, box: 16).rotationEffect(.degrees(t([(150, 0), (850, 360)])))
          KitLabel(g, 13, look.t.textPrimary, weight: 500, "12 hours later")
        }
        .fx(RNTransform(opacity: t.fadeIn(80, 220), ty: t([(80, -6 * g.s), (360, 0)])))
        .pinned(.topTrailing, trailing: (g.W - c.x - c.w + 16) * g.s, top: (c.y + 54) * g.s)
      })
    )
  }
}

struct QuitScene: View {
  let g: KitGeo
  let look: PreviewLook
  let t: KitTracker
  let opts: SceneOpts
  let fresh: Bool

  var body: some View {
    let c = Kit.sideCard(g)
    let away = RNTransform(opacity: t([(180, 1), (420, 0)]), scale: t([(180, 1), (420, 0.97)]))
    let back = RNTransform(opacity: t([(760, 0), (1080, 1)]), scale: t([(760, 0.97), (1080, 1)]))
    let both = RNTransform(opacity: t([(180, 1), (420, 0), (760, 0), (1080, 1)]), scale: t([(180, 1), (420, 0.97), (760, 0.97), (1080, 1)]))
    KitStack {
      KitBackdrop(look: look)
      StdScene(g: g, look: look, opts: opts, n: 5, sel: 0).fx(fresh ? away : both)
      if fresh {
        KitStack {
          SceneChrome(g: g, look: look, opts: opts)
          KitTabRow(g: g, look: look, tab: KitTab.blank, selected: true).row(g, y: Kit.rowY(0, Demo.listTop(opts)))
          KitTabRow(g: g, look: look, tab: KitTab.newTab).row(g, y: Kit.rowY(1, Demo.listTop(opts)))
          KitCard(g: g, look: look, rect: c) { KitNewTabPage(g: g, look: look, width: c.w) }
        }
        .fx(back)
      }
      KeyPress(g: g, look: look, t: t, label: "⌘Q")
    }
  }
}

struct DesktopBackdrop: View {
  let look: PreviewLook

  var body: some View {
    KitBackdrop(look: look.with(tint: look.dark ? Demo.desktopDark : Demo.desktopLight))
  }
}

struct MiniWindow<Content: View>: View {
  let g: KitGeo
  let look: PreviewLook
  let rect: KitRect
  @ViewBuilder let content: () -> Content

  var body: some View {
    KitStack {
      KitSurface(fill: look.tint[1], radius: 11 * g.s, border: [look.dark ? "#FFFFFF26" : "#0000001F"], shadowOpacity: look.dark ? 0.55 : 0.22, shadowRadius: 22 * g.s, shadowY: 10 * g.s)
      KitStack { content() }.clipShape(RoundedRectangle(cornerRadius: 11 * g.s, style: .continuous))
    }
    .at(g, rect)
  }
}

struct MiniSolara: View {
  let g: KitGeo
  let look: PreviewLook
  let rect: KitRect
  let tabs: [KitTab]
  var sel: Int?
  var rowStyle: (Int) -> RNTransform = { _ in .none }
  var extra: AnyView?
  var cardContent: AnyView?

  var body: some View {
    let card = KitRect(x: Demo.miniSide + 7, y: 6, w: rect.w - Demo.miniSide - 14, h: rect.h - 13)
    MiniWindow(g: g, look: look, rect: rect) {
      KitBackdrop(look: look)
      KitLights(g: g)
      if let extra { extra }
      ForEach(Array(tabs.enumerated()), id: \.offset) { i, tab in
        KitTabRow(g: g, look: look, tab: tab, w: Demo.miniSide - 12, selected: i == sel).row(g, y: Kit.rowY(i), w: Demo.miniSide - 12, rowStyle(i))
      }
      KitCard(g: g, look: look, rect: card) {
        KitToolbar(g: g, look: look, w: card.w, tab: tabs.indices.contains(sel ?? 0) ? tabs[sel ?? 0] : KitTab.at(0), icons: [21, 56], crumbX: 84)
        if let cardContent { cardContent } else { KitPage(g: g, look: look, top: Kit.toolbarH) }
      }
    }
  }
}

struct WindowsScene: View {
  let g: KitGeo
  let look: PreviewLook
  let t: KitTracker
  let shared: Bool

  var body: some View {
    let w = (g.W - 50) / 2
    let h = g.H - 56
    let a = KitRect(x: 18, y: 26, w: w, h: h)
    let b = KitRect(x: 32 + w, y: 30, w: w, h: h)
    let list = (0..<4).map(KitTab.at)
    let other = shared ? list : [4, 5, 6].map(KitTab.at)
    let from = (x: a.x + w * 0.62, y: a.y + h * 0.78)
    let to = (x: a.x + 70, y: a.y + Kit.rowY(2) + 14)
    KitStack {
      DesktopBackdrop(look: look)
      MiniSolara(
        g: g, look: look, rect: a, tabs: list,
        rowStyle: { i in shared && i == 1 ? RNTransform(opacity: 0.4) : .none },
        extra: AnyView(KitHighlight(g: g, look: look).row(g, y: Kit.rowY(0), w: Demo.miniSide - 12, RNTransform(ty: t([(520, 0), (820, 2 * Kit.rowPitch * g.s)])))),
        cardContent: AnyView(TwoPages(g: g, look: look, t: t, top: Kit.toolbarH, outAt: 560, inAt: 600, inLength: 260))
      )
      MiniSolara(
        g: g, look: look, rect: b, tabs: other, sel: shared ? 1 : 0,
        rowStyle: { i in
          guard shared else { return .none }
          if i == 0 { return RNTransform(opacity: t([(560, 0.4), (820, 1)])) }
          if i == 2 { return RNTransform(opacity: t([(560, 1), (820, 0.4)])) }
          return .none
        }
      )
      KitCursor(g: g).at(g, 0, 0, 18, 18, RNTransform(
        opacity: t([(100, 0), (260, 1), (1150, 1), (1380, 0)]),
        tx: t([(100, from.x * g.s), (460, to.x * g.s)]),
        ty: t([(100, from.y * g.s), (460, to.y * g.s)]),
        scale: t([(480, 1), (520, 0.85), (640, 1)], .linear)
      ))
    }
  }
}

struct AppearanceScene: View {
  let g: KitGeo
  let t: KitTracker
  let opts: SceneOpts
  let mode: String

  var body: some View {
    let toDark = mode == "auto" ? opts.systemDark : mode == "dark"
    let from = PreviewLook.of(dark: !toDark, accent: opts.accent)
    let to = PreviewLook.of(dark: toDark, accent: opts.accent)
    let label = mode == "auto" ? "Auto · \(toDark ? "Dark" : "Light") like your Mac" : toDark ? "Dark" : "Light"
    KitStack {
      StdScene(g: g, look: from, opts: opts)
      StdScene(g: g, look: to, opts: opts).opacity(t.fadeIn(200, 420))
      KitPill(g: g, look: to) {
        KitGlyph(g: g, name: toDark ? "moon.fill" : "sun.max.fill", size: 14, color: toDark ? "#C7CCE6" : "#E3A21A", weight: .medium, box: 18)
          .rotationEffect(.degrees(t([(460, -90), (900, 0)])))
        KitLabel(g, 13, to.t.textPrimary, weight: 500, label)
      }
      .fx(RNTransform(opacity: t.fadeIn(420, 220), ty: t([(420, 6 * g.s), (700, 0)])))
      .pinned(.bottomLeading, leading: 16 * g.s, bottom: 16 * g.s)
    }
  }
}

struct SiteColorScene: View {
  let g: KitGeo
  let look: PreviewLook
  let t: KitTracker
  let opts: SceneOpts
  let on: Bool

  var body: some View {
    let c = Kit.sideCard(g)
    var toolbarOpts = opts
    toolbarOpts.addressInSidebar = false
    return StdScene(
      g: g, look: look, opts: toolbarOpts,
      page: AnyView(KitStack {
        Rectangle().fill(PreviewColor.color(look.page)).padding(.top, Kit.toolbarH * g.s)
        KitPage(g: g, look: look, top: Kit.toolbarH).fx(RNTransform(opacity: t.fadeIn(80, 320), ty: t([(80, 6 * g.s), (420, 0)])))
      }),
      card: on ? AnyView(KitToolbar(g: g, look: look, w: c.w, tab: KitTab.at(0), site: true).opacity(t.fadeIn(560, 380))) : nil
    )
  }
}

struct TypedScene: View {
  let g: KitGeo
  let look: PreviewLook
  let t: KitTracker
  let opts: SceneOpts
  let search: Bool

  var body: some View {
    let site = KitSuggestion(fav: KitTab.at(6), title: "github.com", detail: "GitHub", hint: "Visit")
    let query = KitSuggestion(icon: "magnifyingglass", title: "github", detail: "Search Google", hint: "Search")
    let rows = search ? [query, site] : [site, query]
    var rect = Demo.centredFrame(g)
    rect.h = 52 + 2 * 35 + 14
    return KitStack {
      StdScene(g: g, look: look, opts: opts)
      KitPanel(g: g, look: look, rect: rect) {
        KitInputRow(g: g, look: look) {
          TypedText(g: g, look: look, t: t, text: Demo.typedText, at: Demo.typeAt, step: Demo.typeStep, caretUntil: search ? 1300 : Demo.typedDone + 100)
          if !search {
            KitLabel(g, 15, look.t.textPrimary, ".com")
              .background(RoundedRectangle(cornerRadius: 2 * g.s).fill(PreviewColor.color(look.t.selection)))
              .opacity(t.step(Demo.typedDone + 100))
          }
        }
        KitDivider(g: g, look: look)
        VStack(spacing: 0) {
          ForEach(Array(rows.enumerated()), id: \.offset) { i, s in
            KitSuggestionRow(g: g, look: look, s: s, selected: i == 0).opacity(t.fadeIn(Demo.typedDone + 140 + Double(i) * 60, 200))
          }
        }
        .padding(.horizontal, 9 * g.s)
        .padding(.top, 4 * g.s)
      }
      .at(g, rect, Demo.drop(t, g, 0))
    }
  }
}

struct AdBox: View {
  let g: KitGeo
  let look: PreviewLook
  let h: Double

  var body: some View {
    RoundedRectangle(cornerRadius: 8 * g.s)
      .fill(PreviewColor.color(look.dark ? "#2A2719" : "#F6F1DE"))
      .overlay(RoundedRectangle(cornerRadius: 8 * g.s).strokeBorder(PreviewColor.color(look.dark ? "#5A5130" : "#E2D6A8"), lineWidth: Kit.hairline))
      .overlay(KitLabel(g, 10, look.dark ? "#B9A867" : "#9C8A45", weight: 600, "AD"))
      .frame(height: h * g.s)
  }
}

struct BlockScene: View {
  let g: KitGeo
  let look: PreviewLook
  let t: KitTracker
  let opts: SceneOpts
  let on: Bool

  func ad(_ ms: Double, _ gone: Double) -> RNTransform {
    RNTransform(
      opacity: on ? t([(ms, 0), (ms + 200, 1), (gone, 1), (gone + 220, 0)]) : t.fadeIn(ms, 200),
      scale: on ? t([(ms, 0.94), (ms + 260, 1), (gone, 1), (gone + 260, 0.86)]) : t([(ms, 0.94), (ms + 260, 1)])
    )
  }

  var body: some View {
    let c = Kit.sideCard(g)
    var toolbarOpts = opts
    toolbarOpts.addressInSidebar = false
    let banner = RNTransform(
      opacity: on ? t([(280, 0), (420, 1), (980, 1), (1220, 0)]) : t.fadeIn(280, 160),
      ty: on ? t([(280, 40 * g.s), (580, 0), (980, 0), (1220, 40 * g.s)]) : t([(280, 40 * g.s), (580, 0)])
    )
    return StdScene(
      g: g, look: look, opts: toolbarOpts,
      page: AnyView(KitPage(g: g, look: look, top: Kit.toolbarH) { AdBox(g: g, look: look, h: 64).fx(ad(200, 900)) }),
      card: AnyView(KitStack {
        AdBox(g: g, look: look, h: 150).at(g, c.w - 150, Kit.toolbarH + 80, 130, 150, ad(120, 820))
        HStack(spacing: 12 * g.s) {
          KitLabel(g, 12.5, look.t.textPrimary, "We use cookies to personalize ads and measure traffic.").frame(maxWidth: .infinity, alignment: .leading)
          KitLabel(g, 12, look.t.goButtonText, weight: 600, "Accept all")
            .padding(.horizontal, 12 * g.s)
            .frame(height: 28 * g.s)
            .background(RoundedRectangle(cornerRadius: 8 * g.s).fill(PreviewColor.color(look.t.goButton)))
        }
        .padding(.horizontal, 16 * g.s)
        .frame(height: 52 * g.s)
        .background(KitSurface(fill: look.t.panel, radius: 12 * g.s, border: [look.t.panelBorder], shadowOpacity: look.dark ? 0.5 : 0.14, shadowRadius: 16 * g.s, shadowY: 4 * g.s))
        .fx(banner)
        .pinned(.bottom, leading: 20 * g.s, trailing: 20 * g.s, bottom: 18 * g.s)
        if on {
          HStack(spacing: 3 * g.s) {
            KitGlyph(g: g, name: "checkmark.shield.fill", size: 14, color: look.t.accent, weight: .medium, box: 18)
            KitLabel(g, 11, look.t.textSecondary, weight: 600, "3")
          }
          .at(g, c.w - 64, 8, 52, 26, alignment: .trailing, RNTransform(opacity: t.fadeIn(700, 200), scale: t([(700, 0.6), (960, 1)])))
        }
      })
    )
  }
}

struct Bubble<Content: View>: View {
  let g: KitGeo
  let look: PreviewLook
  var mine = false
  var plain = true
  @ViewBuilder let content: () -> Content

  var body: some View {
    let shape = RoundedRectangle(cornerRadius: 16 * g.s)
    content()
      .padding(.horizontal, plain ? 12 * g.s : 0)
      .padding(.vertical, plain ? 7 * g.s : 0)
      .background(shape.fill(PreviewColor.color(mine ? "#2F7BF6" : look.dark ? "#3A3A3C" : "#E9E9EB")))
      .clipShape(shape)
  }
}

struct LinksScene: View {
  let g: KitGeo
  let look: PreviewLook
  let t: KitTracker
  let little: Bool

  var body: some View {
    let chat = KitRect(x: 18, y: 40, w: 300, h: g.H - 80)
    let solara = KitRect(x: 300, y: 22, w: g.W - 318, h: g.H - 44)
    let from = (x: chat.x + 250, y: chat.y + chat.h - 40)
    let to = (x: chat.x + 120, y: chat.y + 228)
    let float = KitRect(x: solara.x + 70, y: 70, w: 430, h: g.H - 120)
    let arrived = RNTransform(opacity: t.fadeIn(560, 240), tx: t([(560, -12 * g.s), (860, 0)]))
    let bubbleMax = (chat.w - 28) * 0.82 * g.s
    KitStack {
      DesktopBackdrop(look: look)
      MiniSolara(
        g: g, look: look, rect: solara,
        tabs: little ? [1, 3, 4].map(KitTab.at) : [1, 3, 4, 0].map(KitTab.at),
        sel: little ? 0 : 3,
        rowStyle: { i in !little && i == 3 ? arrived : .none },
        extra: little ? nil : AnyView(KitHighlight(g: g, look: look).row(g, y: Kit.rowY(0), w: Demo.miniSide - 12, RNTransform(opacity: t.fadeOut(560, 200)))),
        cardContent: little
          ? AnyView(KitPage(g: g, look: look, a: .trip, top: Kit.toolbarH))
          : AnyView(KitStack {
            KitPage(g: g, look: look, a: .trip, top: Kit.toolbarH)
            KitPage(g: g, look: look, top: Kit.toolbarH).opacity(t.fadeIn(640, 300))
          })
      )
      MiniWindow(g: g, look: look, rect: chat) {
        Rectangle().fill(PreviewColor.color(look.dark ? "#1E1E1E" : "#FFFFFF"))
        KitLights(g: g, y: 20, x: 20)
        Rectangle().fill(PreviewColor.color(look.t.divider)).at(g, 0, 38, chat.w, Kit.hairline / g.s)
        KitLabel(g, 13, look.t.textPrimary, weight: 600, "Sam").frame(width: chat.w * g.s).offset(y: 13 * g.s)
        VStack(alignment: .leading, spacing: 8 * g.s) {
          Bubble(g: g, look: look) { KitLabel(g, 12.5, look.t.textPrimary, lines: 3, "Found the trail we talked about") }
            .frame(maxWidth: bubbleMax, alignment: .leading)
          Bubble(g: g, look: look, mine: true) { KitLabel(g, 12.5, "#FFFFFF", lines: 3, "Send it!") }
            .frame(maxWidth: .infinity, alignment: .trailing)
          Bubble(g: g, look: look, plain: false) {
            VStack(alignment: .leading, spacing: 0) {
              Rectangle().fill(PreviewColor.color(look.pick(PreviewArticle.notes.far)))
                .frame(height: 70 * g.s)
                .overlay(alignment: .topLeading) {
                  RoundedRectangle(cornerRadius: 80 * g.s).fill(PreviewColor.color(look.pick(PreviewArticle.notes.near)))
                    .frame(width: 210 * g.s * 0.9, height: 120 * g.s)
                    .offset(x: 210 * g.s * 0.3, y: 28 * g.s)
                }
                .clipped()
              VStack(alignment: .leading, spacing: 2 * g.s) {
                KitLabel(g, 12, look.t.textPrimary, weight: 600, "A slow morning on the coast trail")
                KitLabel(g, 11, look.t.textSecondary, "fieldnotes.blog")
              }
              .padding(9 * g.s)
            }
            .overlay(Rectangle().fill(Color.black.opacity(0.12)).opacity(t([(470, 0), (510, 1), (700, 0)], .linear)))
          }
          .frame(width: 210 * g.s)
        }
        .frame(width: (chat.w - 28) * g.s, alignment: .leading)
        .offset(x: 14 * g.s, y: 54 * g.s)
      }
      if little {
        MiniWindow(g: g, look: look, rect: KitRect(x: 0, y: 0, w: float.w, h: float.h)) {
          Rectangle().fill(PreviewColor.color(look.page))
          KitPage(g: g, look: look, top: 38)
          KitStack {
            Rectangle().fill(PreviewColor.color(look.card))
            Rectangle().fill(PreviewColor.color(look.t.divider)).frame(height: Kit.hairline).frame(maxHeight: .infinity, alignment: .bottom)
            KitLights(g: g, y: 19, x: 19)
            KitCrumb(g: g, look: look, tab: KitTab.at(0)).at(g, 84, 10, float.w - 100, 18)
          }
          .frame(width: float.w * g.s, height: 38 * g.s)
        }
        .frame(width: float.w * g.s, height: float.h * g.s, alignment: .topLeading)
        .fx(RNTransform(opacity: t.fadeIn(560, 220), ty: t([(560, 14 * g.s), (900, 0)]), scale: t([(560, 0.9), (900, 1)])))
        .offset(x: float.x * g.s, y: float.y * g.s)
      }
      KitCursor(g: g).at(g, 0, 0, 18, 18, RNTransform(
        opacity: t([(60, 0), (200, 1), (1150, 1), (1400, 0)]),
        tx: t([(60, from.x * g.s), (440, to.x * g.s)]),
        ty: t([(60, from.y * g.s), (440, to.y * g.s)]),
        scale: t([(460, 1), (500, 0.85), (620, 1)], .linear)
      ))
    }
  }
}
