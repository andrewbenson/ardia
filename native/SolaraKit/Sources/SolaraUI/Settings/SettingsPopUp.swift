import AppKit
import SwiftUI

public struct SettingsPopUpItem<Value: Hashable>: Hashable {
  public let value: Value
  public let title: String
  public let separatorBefore: Bool

  public init(_ value: Value, _ title: String, separatorBefore: Bool = false) {
    self.value = value
    self.title = title
    self.separatorBefore = separatorBefore
  }
}

public struct SettingsPopUp<Value: Hashable>: View {
  @Environment(\.colorScheme) private var scheme
  @Environment(\.isEnabled) private var isEnabled
  @Environment(\.settingsPopUpWidth) private var widthOverride
  let items: [SettingsPopUpItem<Value>]
  @Binding var selection: Value
  var minWidth: CGFloat = 120
  @State private var hovered = false

  public init(_ items: [SettingsPopUpItem<Value>], selection: Binding<Value>, minWidth: CGFloat = 120) {
    self.items = items
    _selection = selection
    self.minWidth = minWidth
  }

  public var body: some View {
    let theme = SettingsTheme(scheme)
    Button(action: open) {
      EmptyView()
    }
    .buttonStyle(SettingsPopUpStyle(title: items.first { $0.value == selection }?.title ?? "", minWidth: widthOverride ?? minWidth, hovered: hovered, theme: theme))
    .opacity(isEnabled ? 1 : 0.45)
    .onHover { hovered = $0 }
    .accessibilityRepresentation {
      Picker("", selection: $selection) {
        ForEach(items, id: \.self) { Text($0.title).tag($0.value) }
      }
      .pickerStyle(.menu)
    }
  }

  private func open() {
    let menu = NSMenu()
    menu.autoenablesItems = false
    let target = SettingsPopUpTarget()
    for (index, item) in items.enumerated() {
      if item.separatorBefore { menu.addItem(.separator()) }
      let entry = NSMenuItem(title: item.title, action: #selector(SettingsPopUpTarget.choose(_:)), keyEquivalent: "")
      entry.target = target
      entry.tag = index
      entry.state = item.value == selection ? .on : .off
      menu.addItem(entry)
    }
    menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    if let index = target.chosen, items.indices.contains(index), items[index].value != selection {
      selection = items[index].value
    }
  }
}

public extension SettingsPopUp where Value == String {
  init(_ options: [SettingOption], selection: Binding<String>, minWidth: CGFloat = 120) {
    self.init(options.map { SettingsPopUpItem($0.value, $0.title, separatorBefore: $0.separatorBefore) }, selection: selection, minWidth: minWidth)
  }
}

struct SettingsPopUpStyle: ButtonStyle {
  let title: String
  let minWidth: CGFloat
  let hovered: Bool
  let theme: SettingsTheme

  func makeBody(configuration: Configuration) -> some View {
    HStack(spacing: 6) {
      OnboardingText(title, size: 13, color: theme.textPrimary, lines: 1)
        .frame(maxWidth: .infinity, alignment: .leading)
      Image(systemName: "chevron.up.chevron.down")
        .font(.system(size: 8, weight: .bold))
        .foregroundStyle(Color.white)
        .frame(width: 16, height: 16)
        .background(RoundedRectangle(cornerRadius: 4).fill(theme.accent))
    }
    .padding(.leading, 9)
    .padding(.trailing, 4)
    .frame(width: minWidth, height: 22)
    .background(RoundedRectangle(cornerRadius: 5.5).fill(configuration.isPressed ? theme.controlPressed : hovered ? theme.controlHover : theme.control))
    .overlay(RoundedRectangle(cornerRadius: 5.5).strokeBorder(theme.controlBorder, lineWidth: 1))
    .contentShape(Rectangle())
    .fixedSize()
  }
}

final class SettingsPopUpTarget: NSObject {
  var chosen: Int?

  @objc func choose(_ sender: NSMenuItem) {
    chosen = sender.tag
  }
}

struct SettingsMenuModifier: ViewModifier {
  func body(content: Content) -> some View {
    content
      .menuStyle(.button)
      .buttonStyle(SettingsButtonStyle())
      .menuIndicator(.hidden)
      .fixedSize()
  }
}

extension EnvironmentValues {
  @Entry var settingsPopUpWidth: CGFloat?
}

public extension View {
  func popUpWidth(_ width: CGFloat) -> some View {
    environment(\.settingsPopUpWidth, width)
  }

  func settingsMenu() -> some View {
    modifier(SettingsMenuModifier())
  }
}
