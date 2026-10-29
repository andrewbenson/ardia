import AppKit
import SolaraStore
import SwiftUI
import Testing
@testable import SolaraUI

@MainActor
struct StoreUnavailableViewTests {
  static let folder = URL(fileURLWithPath: "/Users/someone/Library/Application Support/app.solara.browser", isDirectory: true)
  static let cases: [(String, StoreUnavailable)] = [
    ("refused", StoreUnavailable(cause: .refused, detail: "the native store refused to import: session.json has version 99", dataFolder: folder)),
    ("open-failed", StoreUnavailable(cause: .openFailed, detail: "SQLite error 14: unable to open database file", dataFolder: folder)),
    ("open-failed-no-folder", StoreUnavailable(cause: .openFailed, detail: "no data folder", dataFolder: nil)),
  ]

  func view(_ failure: StoreUnavailable, quit: @escaping () -> Void = {}, show: @escaping (URL) -> Void = { _ in }) -> StoreUnavailableView {
    StoreUnavailableView(failure: failure, appName: "Solara", quit: quit, showDataFolder: show)
  }

  @Test func eachCauseSaysWhichOneHappened() {
    let texts = Self.cases.prefix(2).map { view($0.1).title + " " + view($0.1).explanation }
    #expect(texts[0].contains("safely read"))
    #expect(texts[1].contains("couldn't open its data folder"))
    #expect(Set(texts).count == 2)
  }

  @Test func noCauseClaimsAReset() {
    for (_, failure) in Self.cases {
      let text = view(failure).explanation.lowercased()
      #expect(!text.contains("was reset"))
      #expect(!text.contains("deleted"))
    }
  }

  @Test func rendersEveryCase() async throws {
    guard let directory = ProcessInfo.processInfo.environment["SOLARA_SNAPSHOT_DIR"].map({ URL(fileURLWithPath: $0) }) else { return }
    for (name, failure) in Self.cases {
      for dark in [false, true] {
        try await render(view(failure), size: NSSize(width: 820, height: 640), dark: dark, to: directory.appendingPathComponent("\(name)-\(dark ? "dark" : "light").png"))
      }
    }
  }

  func render(_ view: some View, size: NSSize, dark: Bool, to url: URL) async throws {
    _ = NSApplication.shared
    let host = NSHostingView(rootView: view.environment(\.controlActiveState, .key))
    host.sizingOptions = []
    let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.title = "Settings"
    window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    window.contentView = host
    for _ in 0..<6 {
      host.layoutSubtreeIfNeeded()
      window.displayIfNeeded()
      try await Task.sleep(for: .milliseconds(60))
      spin()
    }
    let frameView = try #require(window.contentView?.superview)
    let bitmap = try #require(frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds))
    frameView.cacheDisplay(in: frameView.bounds, to: bitmap)
    let png = try #require(bitmap.representation(using: .png, properties: [:]))
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try png.write(to: url)
    window.contentView = nil
    window.close()
  }

  func spin() {
    RunLoop.main.run(until: Date().addingTimeInterval(0.02))
  }
}
