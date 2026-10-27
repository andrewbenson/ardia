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
  @Environment(\.isEnabled) private var isEnabled
  @Environment(\.settingsFormRowControl) private var inRow
  let items: [SettingsPopUpItem<Value>]
  @Binding var selection: Value
  @State private var anchor = SettingsPopUpAnchor()

  public init(_ items: [SettingsPopUpItem<Value>], selection: Binding<Value>) {
    self.items = items
    _selection = selection
  }

  public var body: some View {
    Button(action: open) {
      HStack(spacing: 12) {
        Text(items.first { $0.value == selection }?.title ?? "")
          .foregroundStyle(.primary)
          .lineLimit(1)
        SettingsPopUpIndicator(symbol: "chevron.up.chevron.down")
      }
      .opacity(isEnabled ? 1 : 0.45)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .fixedSize()
    .padding(.horizontal, SettingsPopUpIndicator.inset)
    .padding(.vertical, inRow ? SettingsPopUpIndicator.popUpRowGrowth : 0)
    .background(SettingsPopUpAnchorView(anchor: anchor))
    .accessibilityRepresentation {
      Picker("", selection: $selection) {
        ForEach(items, id: \.self) { Text($0.title).tag($0.value) }
      }
      .pickerStyle(.menu)
    }
  }

  private func open() {
    guard let view = anchor.view else { return }
    let menu = NSMenu()
    menu.autoenablesItems = false
    menu.font = .systemFont(ofSize: NSFont.systemFontSize)
    let target = SettingsPopUpTarget()
    var selected: NSMenuItem?
    for (index, item) in items.enumerated() {
      if item.separatorBefore { menu.addItem(.separator()) }
      let entry = NSMenuItem(title: item.title, action: #selector(SettingsPopUpTarget.choose(_:)), keyEquivalent: "")
      entry.target = target
      entry.tag = index
      entry.state = item.value == selection ? .on : .off
      if item.value == selection { selected = entry }
      menu.addItem(entry)
    }
    let origin = NSPoint(x: -SettingsPopUpAnchor.menuTextInset, y: view.isFlipped ? 0 : view.bounds.height)
    menu.popUp(positioning: selected, at: origin, in: view)
    if let index = target.chosen, items.indices.contains(index) {
      selection = items[index].value
    }
  }
}

struct SettingsPopUpIndicator: View {
  static let inset: CGFloat = 3.5
  static let menuLeadingInset: CGFloat = 12
  static let popUpRowGrowth: CGFloat = 2.5
  static let menuRowGrowth: CGFloat = -0.5
  @Environment(\.colorScheme) private var scheme
  let symbol: String

  var body: some View {
    Image(systemName: symbol)
      .font(.system(size: 10.5, weight: .semibold))
      .foregroundStyle(.primary)
      .frame(width: 20, height: 20)
      .background(Circle().fill(SettingsFormColors.popUpCircle(scheme)))
  }
}

public struct SettingsMenuButtonStyle: ButtonStyle {
  @Environment(\.isEnabled) private var isEnabled

  public func makeBody(configuration: Configuration) -> some View {
    HStack(spacing: 12) {
      configuration.label
        .foregroundStyle(.primary)
        .lineLimit(1)
      SettingsPopUpIndicator(symbol: "chevron.down")
    }
    .opacity(isEnabled ? (configuration.isPressed ? 0.7 : 1) : 0.45)
    .contentShape(Rectangle())
    .padding(.leading, SettingsPopUpIndicator.menuLeadingInset)
    .padding(.trailing, SettingsPopUpIndicator.inset)
  }
}

struct SettingsMenuModifier: ViewModifier {
  @Environment(\.settingsFormRowControl) private var inRow

  func body(content: Content) -> some View {
    content
      .menuStyle(.button)
      .buttonStyle(SettingsMenuButtonStyle())
      .menuIndicator(.hidden)
      .fixedSize()
      .padding(.vertical, inRow ? SettingsPopUpIndicator.menuRowGrowth : 0)
  }
}

public extension View {
  func settingsMenu() -> some View {
    modifier(SettingsMenuModifier())
  }
}

public extension SettingsPopUp where Value == String {
  init(_ options: [SettingOption], selection: Binding<String>) {
    self.init(options.map { SettingsPopUpItem($0.value, $0.title, separatorBefore: $0.separatorBefore) }, selection: selection)
  }
}

@MainActor
final class SettingsPopUpAnchor {
  static let menuTextInset: CGFloat = 18
  weak var view: NSView?
}

final class SettingsPopUpTarget: NSObject {
  var chosen: Int?

  @objc func choose(_ sender: NSMenuItem) {
    chosen = sender.tag
  }
}

struct SettingsPopUpAnchorView: NSViewRepresentable {
  let anchor: SettingsPopUpAnchor

  func makeNSView(context: Context) -> NSView {
    let view = NSView()
    anchor.view = view
    return view
  }

  func updateNSView(_ view: NSView, context: Context) {
    anchor.view = view
  }
}
