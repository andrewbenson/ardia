import AppKit
import SwiftUI

struct AboutLink: Identifiable {
  let title: String
  let url: URL
  var id: String { title }
}

struct AboutContent {
  let name: String
  let version: String
  let chromium: String?
  let copyright: String
  let upstreamCredit: String?
  let links: [AboutLink]
}

struct AboutView: View {
  let content: AboutContent

  var body: some View {
    VStack(spacing: 0) {
      Image(nsImage: NSApp.applicationIconImage)
        .resizable()
        .frame(width: 88, height: 88)
        .padding(.bottom, 14)
      Text(content.name)
        .font(.system(size: 20, weight: .semibold))
      Text(content.version)
        .font(.system(size: 12))
        .foregroundStyle(.secondary)
        .monospacedDigit()
        .padding(.top, 3)
      if let chromium = content.chromium {
        Text("Chromium \(chromium)")
          .font(.system(size: 11))
          .foregroundStyle(.tertiary)
          .monospacedDigit()
          .padding(.top, 2)
      }
      VStack(spacing: 4) {
        Text(content.copyright)
          .foregroundStyle(.secondary)
        if let credit = content.upstreamCredit {
          Text(credit)
        }
        Text("Free software under the GPL v3, without warranty.")
        Text("Built on Chromium and uBlock Origin.")
      }
      .font(.system(size: 10.5))
      .foregroundStyle(.tertiary)
      .multilineTextAlignment(.center)
      .fixedSize(horizontal: false, vertical: true)
      .padding(.top, 20)
      if !content.links.isEmpty {
        HStack(spacing: 14) {
          ForEach(content.links) { AboutLinkButton(link: $0) }
        }
        .padding(.top, 14)
      }
    }
    .frame(width: 260)
    .padding(.horizontal, 30)
    .padding(.top, 28)
    .padding(.bottom, 26)
  }
}

struct AboutLinkButton: View {
  let link: AboutLink
  @State private var hovered = false

  var body: some View {
    Button(link.title) {
      if ProcessInfo.processInfo.environment["SOLARA_BACKGROUND"] == "1" { return NSLog("[about] background instance, not opening %@", link.url.absoluteString) }
      NSWorkspace.shared.open(link.url)
    }
      .buttonStyle(.plain)
      .font(.system(size: 11, weight: .medium))
      .foregroundStyle(hovered ? .primary : .secondary)
      .focusEffectDisabled()
      .onHover { hovered = $0 }
  }
}

final class AboutWindowController: NSWindowController {
  static let shared = AboutWindowController()

  private init() {
    let window = NSWindow(contentRect: .zero, styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: true)
    window.titlebarAppearsTransparent = true
    window.titleVisibility = .hidden
    window.isMovableByWindowBackground = true
    window.isReleasedWhenClosed = false
    window.standardWindowButton(.miniaturizeButton)?.isHidden = true
    window.standardWindowButton(.zoomButton)?.isHidden = true
    super.init(window: window)
  }

  required init?(coder: NSCoder) { nil }

  func show(_ content: AboutContent) {
    guard let window else { return }
    let hosting = NSHostingView(rootView: AboutView(content: content))
    window.contentView = hosting
    window.setContentSize(hosting.fittingSize)
    window.title = "About \(content.name)"
    if !window.isVisible { window.center() }
    window.makeKeyAndOrderFront(nil)
  }
}
