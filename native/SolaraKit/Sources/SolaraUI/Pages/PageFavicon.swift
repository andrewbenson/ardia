import AppKit
import SwiftUI

@MainActor
public final class PageFavicons {
  private let load: (_ url: String, _ favicon: String?, _ profileId: String) async -> NSImage?
  private let bundledImage: (_ name: String) -> NSImage?
  private var cache: [String: NSImage] = [:]
  private var misses: Set<String> = []
  private var bundledCache: [String: NSImage] = [:]

  public init(
    load: @escaping (_ url: String, _ favicon: String?, _ profileId: String) async -> NSImage?,
    bundled: @escaping (_ name: String) -> NSImage? = { _ in nil }
  ) {
    self.load = load
    bundledImage = bundled
  }

  static func key(_ url: String, _ favicon: String?, _ profileId: String) -> String { "\(profileId)\u{1}\(favicon ?? "")\u{1}\(url)" }

  func cached(_ url: String, _ favicon: String?, _ profileId: String) -> NSImage? { cache[Self.key(url, favicon, profileId)] }

  func fetch(_ url: String, _ favicon: String?, _ profileId: String) async -> NSImage? {
    let key = Self.key(url, favicon, profileId)
    if let image = cache[key] { return image }
    if misses.contains(key) { return nil }
    guard let image = await load(url, favicon, profileId) else {
      misses.insert(key)
      return nil
    }
    cache[key] = image
    return image
  }

  func bundled(_ url: String, dark: Bool) -> NSImage? {
    guard let name = BundledSiteIcons.name(for: url, dark: dark) else { return nil }
    if let image = bundledCache[name] { return image }
    guard let image = bundledImage(name) else { return nil }
    bundledCache[name] = image
    return image
  }
}

struct PageFaviconsKey: EnvironmentKey {
  static let defaultValue: PageFavicons? = nil
}

extension EnvironmentValues {
  var pageFavicons: PageFavicons? {
    get { self[PageFaviconsKey.self] }
    set { self[PageFaviconsKey.self] = newValue }
  }
}

struct PageFavicon: View {
  @Environment(\.pageTheme) private var theme
  @Environment(\.pageFavicons) private var favicons
  let url: String
  var favicon: String?
  var profileId = ""
  var size: CGFloat = 16
  @State private var image: NSImage?

  var body: some View {
    Group {
      if let shown = image ?? favicons?.cached(url, favicon, profileId) ?? favicons?.bundled(url, dark: theme.dark) {
        Image(nsImage: shown)
          .resizable()
          .interpolation(.high)
          .clipShape(RoundedRectangle(cornerRadius: size > 18 ? 4 : 3, style: .circular))
      } else if let initial = SettingsFavicon.hostInitial(url, displayHost: { displayHostLabel($0) }) {
        let tile = (size * 14 / 16).rounded()
        RoundedRectangle(cornerRadius: tile * 0.32, style: .continuous)
          .fill(theme.dark ? Color(.sRGB, red: 247 / 255, green: 245 / 255, blue: 1, opacity: 0.2) : Color.black.opacity(0.13))
          .frame(width: tile, height: tile)
          .overlay {
            Text(initial)
              .font(.system(size: (tile * 0.64).rounded(), weight: .semibold))
              .foregroundStyle(theme.textSecondary)
          }
      } else {
        Image(systemName: "globe").font(.system(size: size - 3)).foregroundStyle(theme.textSecondary)
      }
    }
    .frame(width: size, height: size)
    .task(id: PageFavicons.key(url, favicon, profileId)) { image = await favicons?.fetch(url, favicon, profileId) }
    .accessibilityHidden(true)
  }

  private func displayHostLabel(_ host: String) -> String { PageFormat.displayHost(host) }
}
