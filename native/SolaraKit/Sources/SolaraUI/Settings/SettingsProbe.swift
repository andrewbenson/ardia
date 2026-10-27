import SwiftUI

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
