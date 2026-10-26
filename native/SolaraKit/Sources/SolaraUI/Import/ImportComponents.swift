import AppKit
import SwiftUI

struct ImportColors {
  let dark: Bool

  init(_ scheme: ColorScheme) {
    dark = scheme == .dark
  }

  var accent: Color { dark ? Color(red: 10 / 255, green: 132 / 255, blue: 1) : Color(red: 0, green: 122 / 255, blue: 1) }
  var group: Color { dark ? Color.white.opacity(0.045) : Color.black.opacity(0.028) }
  var groupBorder: Color { dark ? Color.white.opacity(0.07) : Color.black.opacity(0.07) }
  var selected: Color { dark ? Color.white.opacity(0.1) : Color.black.opacity(0.06) }
  var control: Color { dark ? Color.white.opacity(0.1) : Color.white }
  var controlBorder: Color { dark ? Color.white.opacity(0.08) : Color.black.opacity(0.14) }
  var textPrimary: Color { dark ? Color.white : Color.black }
  var textSecondary: Color { (dark ? Color.white : Color.black).opacity(0x80 / 255) }
  var textTertiary: Color { (dark ? Color.white : Color.black).opacity(0x59 / 255) }
  var icon: Color { dark ? Color(red: 0xF7 / 255, green: 0xF5 / 255, blue: 1).opacity(0xC6 / 255) : Color.black.opacity(0xC6 / 255) }
  var divider: Color { dark ? Color.white.opacity(0.08) : Color.black.opacity(0.08) }
  var rowHover: Color { dark ? Color.white.opacity(0.07) : Color(red: 15 / 255, green: 24 / 255, blue: 44 / 255).opacity(0.05) }
  var window: Color { dark ? Color(red: 0x1E / 255, green: 0x1E / 255, blue: 0x1E / 255) : Color(red: 0xF4 / 255, green: 0xF4 / 255, blue: 0xF4 / 255) }
  var dropBorder: Color { dark ? Color.white.opacity(0.25) : Color.black.opacity(0.2) }
  static let success = Color(red: 0x30 / 255, green: 0xD1 / 255, blue: 0x58 / 255)
  static let warning = Color(red: 1, green: 0x9F / 255, blue: 0x0A / 255)
  static let hairline: CGFloat = 1
}

extension Color {
  init?(importHex hex: String?) {
    guard let hex else { return nil }
    let digits = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
    guard digits.count >= 6, let value = UInt32(digits.prefix(6), radix: 16) else { return nil }
    self.init(red: Double((value >> 16) & 255) / 255, green: Double((value >> 8) & 255) / 255, blue: Double(value & 255) / 255)
  }
}

struct ImportTitle: View {
  @Environment(\.colorScheme) private var scheme
  let title: String
  var subtitle: String?
  var spinner = false

  var body: some View {
    let colors = ImportColors(scheme)
    VStack(alignment: .leading, spacing: 6) {
      Text(title)
        .font(.system(size: 22, weight: .bold))
        .foregroundStyle(colors.textPrimary)
        .fixedSize(horizontal: false, vertical: true)
      if let subtitle {
        HStack(alignment: .center, spacing: 8) {
          if spinner { ProgressView().controlSize(.small) }
          Text(subtitle)
            .font(.system(size: 13))
            .lineSpacing(2)
            .foregroundStyle(colors.textSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.bottom, 20)
  }
}

struct ImportNote: View {
  @Environment(\.colorScheme) private var scheme
  let text: String

  var body: some View {
    Text(text)
      .font(.system(size: 13))
      .foregroundStyle(ImportColors(scheme).textSecondary)
      .multilineTextAlignment(.center)
      .frame(maxWidth: .infinity)
      .padding(.top, 20)
  }
}

struct ImportErrorText: View {
  let text: String

  var body: some View {
    Text(text)
      .font(.system(size: 12))
      .foregroundStyle(ImportColors.warning)
      .frame(maxWidth: .infinity, alignment: .leading)
      .fixedSize(horizontal: false, vertical: true)
      .padding(.top, 12)
  }
}

struct ImportSectionLabel: View {
  @Environment(\.colorScheme) private var scheme
  let text: String

  var body: some View {
    Text(text)
      .font(.system(size: 12, weight: .semibold))
      .foregroundStyle(ImportColors(scheme).textSecondary)
      .frame(maxWidth: .infinity, alignment: .leading)
      .fixedSize(horizontal: false, vertical: true)
      .padding(.bottom, 8)
  }
}

struct ImportFileIcon: View {
  @Environment(\.colorScheme) private var scheme
  let path: String?
  let size: CGFloat
  var fallback: String? = nil
  var round = false

  var body: some View {
    if let path, let image = NSImage(contentsOfFile: path) {
      Image(nsImage: image)
        .resizable()
        .interpolation(.high)
        .aspectRatio(contentMode: round ? .fill : .fit)
        .frame(width: size, height: size)
        .clipShape(round ? AnyShape(Circle()) : AnyShape(Rectangle()))
    } else if let fallback {
      Image(systemName: fallback)
        .font(.system(size: 22))
        .foregroundStyle(ImportColors(scheme).icon)
        .frame(width: size, height: size)
    }
  }
}

struct ImportRadio: View {
  @Environment(\.colorScheme) private var scheme
  let on: Bool

  var body: some View {
    let colors = ImportColors(scheme)
    ZStack {
      Circle().fill(on ? colors.accent : colors.control)
      if !on { Circle().strokeBorder(colors.controlBorder, lineWidth: 1) }
      if on { Circle().fill(Color.white).frame(width: 6, height: 6) }
    }
    .frame(width: 16, height: 16)
  }
}

struct ImportBrowserRow: View {
  @Environment(\.colorScheme) private var scheme
  @State private var hovered = false
  let browser: ImportBrowser
  let selected: Bool
  let onPress: () -> Void

  var body: some View {
    let colors = ImportColors(scheme)
    let detail = ImportModel.detail(browser)
    Button(action: onPress) {
      HStack(spacing: 12) {
        ImportRadio(on: selected)
        ImportFileIcon(path: browser.iconPath, size: 32, fallback: "globe")
        Text(browser.name)
          .font(.system(size: 14, weight: .medium))
          .foregroundStyle(colors.textPrimary)
          .frame(maxWidth: .infinity, alignment: .leading)
        if !detail.isEmpty {
          Text(detail)
            .font(.system(size: 12))
            .foregroundStyle(colors.textSecondary)
        }
        if browser.needsKeychain {
          Image(systemName: "lock")
            .font(.system(size: 11))
            .foregroundStyle(colors.textTertiary)
            .frame(width: 14, height: 14)
        }
      }
      .padding(.horizontal, 12)
      .frame(height: 52)
      .background(
        RoundedRectangle(cornerRadius: 10, style: .continuous)
          .fill(selected ? colors.accent.opacity(0x26 / 255) : hovered ? colors.selected : colors.group)
      )
      .overlay(
        RoundedRectangle(cornerRadius: 10, style: .continuous)
          .strokeBorder(selected ? colors.accent : colors.groupBorder, lineWidth: selected ? 1.5 : ImportColors.hairline)
      )
      .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
    .buttonStyle(.plain)
    .onHover { hovered = $0 }
    .accessibilityAddTraits(selected ? .isSelected : [])
  }
}

struct ImportSelectRow<Icon: View>: View {
  @Environment(\.colorScheme) private var scheme
  let selected: Bool
  let onToggle: (Bool) -> Void
  let title: String
  var subtitle: String?
  @ViewBuilder let icon: Icon

  var body: some View {
    let colors = ImportColors(scheme)
    HStack(spacing: 12) {
      Toggle("", isOn: Binding(get: { selected }, set: { value in onToggle(value) }))
        .toggleStyle(.checkbox)
        .labelsHidden()
      icon
      VStack(alignment: .leading, spacing: 1) {
        Text(title)
          .font(.system(size: 13.5))
          .foregroundStyle(colors.textPrimary)
        if let subtitle {
          Text(subtitle)
            .font(.system(size: 11.5))
            .foregroundStyle(colors.textSecondary)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 6)
    .frame(minHeight: 48)
    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(colors.group))
    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(colors.groupBorder, lineWidth: ImportColors.hairline))
    .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    .onTapGesture { onToggle(!selected) }
  }
}

struct ImportMonogram: View {
  let name: String
  let color: String?

  var body: some View {
    let letter = name.trimmingCharacters(in: .whitespacesAndNewlines).first.map { String($0).uppercased() } ?? "?"
    Circle()
      .fill(Color(importHex: color) ?? Color(red: 0x8E / 255, green: 0x8E / 255, blue: 0x93 / 255))
      .frame(width: 28, height: 28)
      .overlay(Text(letter).font(.system(size: 13, weight: .semibold)).foregroundStyle(Color.white))
  }
}

struct ImportSpaceIcon: View {
  let space: ImportSpace

  var body: some View {
    RoundedRectangle(cornerRadius: 8, style: .continuous)
      .fill(Color(importHex: space.color) ?? Color(red: 0x8E / 255, green: 0x8E / 255, blue: 0x93 / 255))
      .frame(width: 28, height: 28)
      .overlay {
        if let emoji = space.emoji, !emoji.isEmpty {
          Text(emoji).font(.system(size: 15))
        } else {
          Image(systemName: "square.stack").font(.system(size: 12)).foregroundStyle(Color.white)
        }
      }
  }
}

struct ImportCategoryRow: View {
  @Environment(\.colorScheme) private var scheme
  @State private var appeared = false
  @State private var checked = false
  let kind: ImportKind
  let status: ImportStatus
  let index: Int

  var body: some View {
    let colors = ImportColors(scheme)
    let active = status == .active
    HStack(spacing: 12) {
      Image(systemName: kind.symbol)
        .font(.system(size: 13))
        .foregroundStyle(status == .pending ? colors.textTertiary : colors.icon)
        .frame(width: 20, height: 20)
      Text(kind.title)
        .font(.system(size: 13))
        .foregroundStyle(status == .pending ? colors.textSecondary : colors.textPrimary)
        .frame(maxWidth: .infinity, alignment: .leading)
      if active {
        ProgressView().controlSize(.small)
      } else if status != .pending {
        Image(systemName: status == .done ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
          .font(.system(size: 15))
          .foregroundStyle(status == .done ? ImportColors.success : ImportColors.warning)
          .frame(width: 20, height: 20)
          .scaleEffect(checked ? 1 : 0)
      }
    }
    .padding(.horizontal, 12)
    .frame(height: 44)
    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(active ? colors.accent.opacity(0x1F / 255) : colors.group))
    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(active ? colors.accent.opacity(0x66 / 255) : colors.groupBorder, lineWidth: ImportColors.hairline))
    .opacity(appeared ? 1 : 0)
    .offset(y: appeared ? 0 : 8)
    .onAppear {
      withAnimation(.timingCurve(0.33, 1, 0.68, 1, duration: 0.26).delay(Double(index) * 0.07)) { appeared = true }
      if status == .done || status == .failed { settle() }
    }
    .onChange(of: status) { _, next in
      if next == .done || next == .failed { settle() }
    }
  }

  private func settle() {
    withAnimation(.interpolatingSpring(stiffness: 160, damping: 10)) { checked = true }
  }
}

struct ImportSuccessMark: View {
  @State private var scale = 0.4

  var body: some View {
    Image(systemName: "checkmark.circle.fill")
      .font(.system(size: 46))
      .foregroundStyle(ImportColors.success)
      .frame(width: 60, height: 60)
      .scaleEffect(scale)
      .onAppear {
        withAnimation(.interpolatingSpring(stiffness: 120, damping: 10)) { scale = 1 }
      }
  }
}

struct ImportSettingsSteps: View {
  @Environment(\.colorScheme) private var scheme
  let steps: [String]
  let openTitle: String
  let onOpen: () -> Void
  let onRecheck: () -> Void

  var body: some View {
    let colors = ImportColors(scheme)
    VStack(alignment: .leading, spacing: 10) {
      ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
        HStack(spacing: 10) {
          Circle()
            .fill(colors.rowHover)
            .frame(width: 20, height: 20)
            .overlay(Text("\(index + 1)").font(.system(size: 11, weight: .semibold)).foregroundStyle(colors.textSecondary))
          Text(step)
            .font(.system(size: 13))
            .foregroundStyle(colors.textPrimary)
        }
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.bottom, 16)
    HStack(spacing: 10) {
      Button(openTitle, action: onOpen).buttonStyle(.borderedProminent)
      Button("Check Again", action: onRecheck)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.bottom, 18)
  }
}

struct ImportFileDrop: View {
  @Environment(\.colorScheme) private var scheme
  @State private var over = false
  let onFile: (String) -> Void
  let onChoose: () -> Void

  var body: some View {
    let colors = ImportColors(scheme)
    VStack(spacing: 10) {
      Image(systemName: "doc.zipper")
        .font(.system(size: 24))
        .foregroundStyle(colors.textSecondary)
        .frame(width: 32, height: 32)
      Text("Choose .zip file or drag it here")
        .font(.system(size: 13))
        .foregroundStyle(colors.textSecondary)
      Button("Choose .zip file", action: onChoose)
    }
    .frame(maxWidth: .infinity)
    .frame(height: 130)
    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(over ? colors.accent.opacity(0x1A / 255) : Color.clear))
    .overlay(
      RoundedRectangle(cornerRadius: 12, style: .continuous)
        .strokeBorder(over ? colors.accent : colors.dropBorder, style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
    )
    .dropDestination(for: URL.self) { urls, _ in
      guard let url = urls.first(where: \.isFileURL) else { return false }
      onFile(url.path)
      return true
    } isTargeted: { over = $0 }
  }
}

struct ImportDragRegion: NSViewRepresentable {
  final class Region: NSView {
    override var mouseDownCanMoveWindow: Bool { true }

    override func mouseDown(with event: NSEvent) {
      window?.performDrag(with: event)
    }
  }

  func makeNSView(context: Context) -> Region { Region() }

  func updateNSView(_ view: Region, context: Context) {}
}

struct ImportBackdrop: NSViewRepresentable {
  func makeNSView(context: Context) -> NSVisualEffectView {
    let view = NSVisualEffectView()
    view.material = .windowBackground
    view.blendingMode = .behindWindow
    view.state = .followsWindowActiveState
    return view
  }

  func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}
