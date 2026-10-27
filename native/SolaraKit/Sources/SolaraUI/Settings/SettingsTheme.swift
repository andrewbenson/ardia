import SwiftUI

struct SettingsTheme {
  let dark: Bool

  init(_ scheme: ColorScheme) {
    dark = scheme == .dark
  }

  static func rgba(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) -> Color {
    Color(.sRGB, red: r / 255, green: g / 255, blue: b / 255, opacity: a)
  }

  var window: Color { dark ? Self.rgba(0x1E, 0x1E, 0x1E) : Self.rgba(0xF2, 0xF2, 0xF2) }
  var sidebarDivider: Color { dark ? Self.rgba(0, 0, 0, 0.6) : Self.rgba(0, 0, 0, 0.1) }

  var textPrimary: Color { dark ? Self.rgba(255, 255, 255) : Self.rgba(0, 0, 0) }
  var textSecondary: Color { dark ? Self.rgba(255, 255, 255, 0x80 / 255) : Self.rgba(0, 0, 0, 0x80 / 255) }
  var textTertiary: Color { dark ? Self.rgba(255, 255, 255, 0x59 / 255) : Self.rgba(0, 0, 0, 0x59 / 255) }
  var icon: Color { dark ? Self.rgba(0xF7, 0xF5, 0xFF, 0xC6 / 255) : Self.rgba(0, 0, 0, 0xC6 / 255) }
  var iconDisabled: Color { dark ? Self.rgba(0xF7, 0xF5, 0xFF, 0x4D / 255) : Self.rgba(0, 0, 0, 0x4D / 255) }
  var toolbarHover: Color { dark ? Self.rgba(255, 255, 255, 0.1) : Self.rgba(0, 0, 0, 0.06) }
  var toolbarPressed: Color { dark ? Self.rgba(255, 255, 255, 0.18) : Self.rgba(0, 0, 0, 0.1) }

  var group: Color { dark ? Self.rgba(255, 255, 255, 0.045) : Self.rgba(0, 0, 0, 0.028) }
  var groupBorder: Color { dark ? Self.rgba(255, 255, 255, 0.07) : Self.rgba(0, 0, 0, 0.07) }
  var separator: Color { dark ? Self.rgba(255, 255, 255, 0.07) : Self.rgba(0, 0, 0, 0.07) }
  var control: Color { dark ? Self.rgba(255, 255, 255, 0.1) : Self.rgba(255, 255, 255) }
  var controlHover: Color { dark ? Self.rgba(255, 255, 255, 0.14) : Self.rgba(0xF7, 0xF7, 0xF7) }
  var controlPressed: Color { dark ? Self.rgba(255, 255, 255, 0.2) : Self.rgba(0xEB, 0xEB, 0xEB) }
  var controlBorder: Color { dark ? Self.rgba(255, 255, 255, 0.08) : Self.rgba(0, 0, 0, 0.14) }
  var field: Color { dark ? Self.rgba(0, 0, 0, 0.25) : Self.rgba(255, 255, 255) }
  var fieldBorder: Color { dark ? Self.rgba(255, 255, 255, 0.12) : Self.rgba(0, 0, 0, 0.14) }
  var switchOff: Color { dark ? Self.rgba(255, 255, 255, 0.14) : Self.rgba(0, 0, 0, 0.1) }
  var accent: Color { dark ? Self.rgba(0x0A, 0x84, 0xFF) : Self.rgba(0x00, 0x7A, 0xFF) }
  var accentPressed: Color { Self.rgba(0x00, 0x60, 0xD0) }
  var destructive: Color { dark ? Self.rgba(0xFF, 0x45, 0x3A) : Self.rgba(0xFF, 0x3B, 0x30) }
  var selected: Color { dark ? Self.rgba(255, 255, 255, 0.1) : Self.rgba(0, 0, 0, 0.06) }
  var flash: Color { dark ? Self.rgba(10, 132, 255, 0.22) : Self.rgba(0, 122, 255, 0.16) }
}

struct SettingsVisualEffect: NSViewRepresentable {
  func makeNSView(context: Context) -> NSVisualEffectView {
    let view = NSVisualEffectView()
    view.material = .sidebar
    view.blendingMode = .behindWindow
    view.state = .followsWindowActiveState
    return view
  }

  func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

@MainActor
public enum SettingsProbe {
  public struct Switch: Sendable {
    public var frame: CGRect
    public var on: Bool
  }

  public static var enabled = false
  public static var switches: [UUID: Switch] = [:]
}

struct SettingsProbeSwitch: ViewModifier {
  let on: Bool
  @State private var id = UUID()

  func body(content: Content) -> some View {
    if SettingsProbe.enabled {
      content
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
          SettingsProbe.switches[id] = SettingsProbe.Switch(frame: frame, on: on)
        }
        .onChange(of: on) { _, now in SettingsProbe.switches[id]?.on = now }
        .onDisappear { SettingsProbe.switches[id] = nil }
    } else {
      content
    }
  }
}
