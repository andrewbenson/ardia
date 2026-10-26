import SwiftUI

struct SettingsChoiceCard<Preview: View>: View {
  @Environment(\.colorScheme) private var scheme
  let title: String
  let selected: Bool
  var height: CGFloat = 84
  var radius: CGFloat = 9
  var help: String?
  let action: () -> Void
  let preview: Preview

  init(title: String, selected: Bool, height: CGFloat = 84, radius: CGFloat = 9, help: String? = nil, action: @escaping () -> Void, @ViewBuilder preview: () -> Preview) {
    self.title = title
    self.selected = selected
    self.height = height
    self.radius = radius
    self.help = help
    self.action = action
    self.preview = preview()
  }

  var body: some View {
    Button(action: action) {
      VStack(spacing: 7) {
        preview
          .frame(maxWidth: .infinity)
          .frame(height: height)
          .clipShape(RoundedRectangle(cornerRadius: radius))
          .overlay {
            RoundedRectangle(cornerRadius: radius)
              .strokeBorder(selected ? Color.accentColor : SettingsPreviewColors.groupBorder(scheme), lineWidth: selected ? 2.5 : 1)
          }
        HStack(spacing: 5) {
          if selected {
            Image(systemName: "checkmark.circle.fill")
              .font(.system(size: 12))
              .foregroundStyle(Color.accentColor)
          }
          Text(title)
            .font(.system(size: 12))
            .foregroundStyle(selected ? .primary : .secondary)
        }
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .help(help ?? "")
  }
}

enum SettingsPreviewColors {
  static func groupBorder(_ scheme: ColorScheme) -> Color {
    scheme == .dark ? Color.white.opacity(0.07) : Color.black.opacity(0.07)
  }

  static func bar(_ scheme: ColorScheme) -> Color {
    scheme == .dark ? Color.white.opacity(0.22) : Color.black.opacity(0.16)
  }

  static func page(_ scheme: ColorScheme) -> Color {
    scheme == .dark ? Color.white.opacity(0.08) : Color.white
  }

  static func field(_ scheme: ColorScheme) -> Color {
    scheme == .dark ? Color.white.opacity(0.14) : Color.black.opacity(0.08)
  }

  static func window(_ scheme: ColorScheme) -> Color {
    scheme == .dark ? Color(red: 0x2A / 255, green: 0x2A / 255, blue: 0x2C / 255) : Color(red: 0xE9 / 255, green: 0xE9 / 255, blue: 0xEB / 255)
  }
}
