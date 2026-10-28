import AppKit
import SwiftUI
import Testing
@testable import SolaraUI

enum Snapshot {
  nonisolated static var directory: URL? {
    ProcessInfo.processInfo.environment["SOLARA_SNAPSHOT_DIR"].map { URL(fileURLWithPath: $0) }
  }

  @MainActor
  static func render(_ view: some View, size: NSSize, dark: Bool, to url: URL) async throws {
    _ = NSApplication.shared
    let host = NSHostingView(rootView: view.environment(\.controlActiveState, .key))
    let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.titlebarAppearsTransparent = true
    window.titleVisibility = .visible
    window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    window.contentView = host
    for _ in 0..<6 {
      host.layoutSubtreeIfNeeded()
      window.displayIfNeeded()
      try await Task.sleep(for: .milliseconds(60))
      spin()
    }
    let frameView = try #require(window.contentView?.superview)
    let frame = frameView.bounds
    let bitmap = try #require(frameView.bitmapImageRepForCachingDisplay(in: frame))
    frameView.cacheDisplay(in: frame, to: bitmap)
    let png = try #require(bitmap.representation(using: .png, properties: [:]))
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try png.write(to: url)
    window.contentView = nil
    window.close()
  }

  @MainActor
  static func renderPanes(_ context: SettingsContext, _ panes: [SettingsPane], places: [SettingsPlace] = [], named name: (SettingsPlace) -> String = { $0.pane.rawValue }) async throws {
    guard let directory else { return }
    for place in panes.map({ SettingsPlace(pane: $0) }) + places {
      context.navigation.go(place.pane, profileId: place.profileId, detail: place.detail)
      context.syncShown()
      for dark in [false, true] {
        let scheme = dark ? "dark" : "light"
        try await render(SettingsWindowView(context: context), size: windowSize, dark: dark, to: directory.appendingPathComponent("\(name(place))-\(scheme).png"))
        try await render(SettingsWindowView(context: context), size: tallSize, dark: dark, to: directory.appendingPathComponent("\(name(place))-\(scheme)-full.png"))
      }
    }
  }

  static let windowSize = NSSize(width: 820, height: 640)
  static let tallSize = NSSize(width: 820, height: 2000)

  @MainActor
  static func spin() {
    RunLoop.main.run(until: Date().addingTimeInterval(0.02))
  }
}

@MainActor
struct SettingsSnapshotTests {
  @Test(.enabled(if: Snapshot.directory != nil))
  func rendersGeneral() async throws {
    let (context, _) = await SettingsFixture.loaded()
    try await Snapshot.renderPanes(context, [.general])
  }

  @Test(.enabled(if: Snapshot.directory != nil))
  func rendersSearchResults() async throws {
    let directory = try #require(Snapshot.directory)
    let (context, _) = await SettingsFixture.loaded()
    context.search.query = "tabs"
    context.search.selected = 1
    for dark in [false, true] {
      try await Snapshot.render(SettingsWindowView(context: context), size: Snapshot.windowSize, dark: dark, to: directory.appendingPathComponent("search-tabs-\(dark ? "dark" : "light").png"))
    }
  }
}
