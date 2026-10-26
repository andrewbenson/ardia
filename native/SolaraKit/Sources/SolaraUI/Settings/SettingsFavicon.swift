import AppKit
import SwiftUI

@MainActor
public final class SettingsFavicons {
  private let load: (String) async -> NSImage?
  private var cache: [String: NSImage] = [:]

  public init(load: @escaping (String) async -> NSImage?) {
    self.load = load
  }

  func cached(_ url: String) -> NSImage? { cache[url] }

  func fetch(_ url: String) async -> NSImage? {
    if let image = cache[url] { return image }
    guard let image = await load(url) else { return nil }
    cache[url] = image
    return image
  }
}

struct SettingsFavicon: View {
  @Environment(\.settingsContext) private var context
  @State private var image: NSImage?
  let url: String
  var size: CGFloat = 16

  var body: some View {
    Group {
      if let image = image ?? context?.favicons?.cached(url) {
        Image(nsImage: image)
          .resizable()
          .interpolation(.high)
      } else {
        Image(systemName: "globe")
          .font(.system(size: size * 0.8))
          .foregroundStyle(.secondary)
      }
    }
    .frame(width: size, height: size)
    .task(id: url) { image = await context?.favicons?.fetch(url) }
  }
}
