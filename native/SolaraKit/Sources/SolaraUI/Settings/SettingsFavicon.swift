import AppKit
import SwiftUI

@MainActor
public final class SettingsFavicons {
  private let load: (String, String?) async -> NSImage?
  let displayHost: (String) -> String
  private var cache: [String: NSImage] = [:]

  public init(displayHost: @escaping (String) -> String = { $0 }, load: @escaping (_ url: String, _ profile: String?) async -> NSImage?) {
    self.displayHost = displayHost
    self.load = load
  }

  static func key(_ url: String, _ profile: String?) -> String { "\(profile ?? "") \(url)" }

  func cached(_ url: String, profile: String?) -> NSImage? { cache[Self.key(url, profile)] }

  func fetch(_ url: String, profile: String?) async -> NSImage? {
    let key = Self.key(url, profile)
    if let image = cache[key] { return image }
    guard let image = await load(url, profile) else { return nil }
    cache[key] = image
    return image
  }
}

struct SettingsFavicon: View {
  @Environment(\.settingsContext) private var context
  @Environment(\.colorScheme) private var colorScheme
  @State private var image: NSImage?
  let url: String
  var profile: String?
  var size: CGFloat = 16

  var body: some View {
    Group {
      if let image = image ?? context?.favicons?.cached(url, profile: profile) {
        Image(nsImage: image)
          .resizable()
          .interpolation(.high)
          .clipShape(RoundedRectangle(cornerRadius: size > 18 ? 4 : 3))
      } else if let initial = Self.hostInitial(url, displayHost: context?.favicons?.displayHost ?? { $0 }) {
        let tile = (size * 14 / 16).rounded()
        RoundedRectangle(cornerRadius: tile * 0.32, style: .continuous)
          .fill(colorScheme == .dark ? Color(red: 247 / 255, green: 245 / 255, blue: 1).opacity(0.2) : Color.black.opacity(0.13))
          .frame(width: tile, height: tile)
          .overlay {
            Text(initial)
              .font(.system(size: (tile * 0.64).rounded(), weight: .semibold))
              .foregroundStyle(.secondary)
          }
      } else {
        Image(systemName: "globe")
          .font(.system(size: size - 3))
          .foregroundStyle(.secondary)
      }
    }
    .frame(width: size, height: size)
    .task(id: SettingsFavicons.key(url, profile)) { image = await context?.favicons?.fetch(url, profile: profile) }
  }

  static func hostInitial(_ url: String, displayHost: (String) -> String = { $0 }) -> String? {
    guard let match = url.firstMatch(of: /^(?i:https?|ftp):\/\/(?:[^@\/?#]*@)?([^\/?#:]+)/) else { return nil }
    let host = String(match.1)
    guard host.wholeMatch(of: /[\d.]+/) == nil, !host.hasPrefix("[") else { return nil }
    var shown = displayHost(host.lowercased())
    if shown.hasPrefix("www.") { shown.removeFirst(4) }
    return shown.first.map { String($0).uppercased() }
  }
}
