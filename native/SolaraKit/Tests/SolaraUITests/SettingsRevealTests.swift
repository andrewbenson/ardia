import AppKit
import SwiftUI
import Testing
@testable import SolaraUI

@MainActor
struct SettingsRevealTests {
  static func host(_ context: SettingsContext) -> (NSWindow, NSHostingView<SettingsWindowView>) {
    _ = NSApplication.shared
    let host = NSHostingView(rootView: SettingsWindowView(context: context))
    let window = NSWindow(contentRect: NSRect(origin: .zero, size: Snapshot.windowSize), styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = host
    return (window, host)
  }

  static func settle(_ host: NSView, for seconds: Double = 0.6) async throws {
    let end = Date().addingTimeInterval(seconds)
    while Date() < end {
      host.layoutSubtreeIfNeeded()
      host.window?.displayIfNeeded()
      try await Task.sleep(for: .milliseconds(20))
    }
  }

  static func scrollViews(in view: NSView) -> [NSScrollView] {
    (view as? NSScrollView).map { [$0] } ?? [] + view.subviews.flatMap(scrollViews(in:))
  }

  func reveal(_ id: String, in pane: SettingsPane, context: SettingsContext) async throws {
    let (window, host) = Self.host(context)
    defer { window.close() }
    context.navigation.go(pane)
    context.syncShown()
    try await Self.settle(host)
    context.search.revealSetting(id, navigation: context.navigation) { _, _ in nil }
    try await Self.settle(host)
    #expect(context.search.flash?.id == id)
    let deadline = Date().addingTimeInterval(4)
    var offsets = Self.scrollViews(in: host).map(\.contentView.bounds.origin.y)
    while !offsets.contains(where: { $0 > 100 }), Date() < deadline {
      try await Self.settle(host, for: 0.1)
      offsets = Self.scrollViews(in: host).map(\.contentView.bounds.origin.y)
    }
    #expect(offsets.contains { $0 > 100 })
    context.search.revealSetting(id, navigation: context.navigation) { _, _ in nil }
    try await Self.settle(host)
    let frame = try #require(context.anchorFrames[id])
    #expect(frame.minY >= context.viewport.minY)
    #expect(frame.maxY <= context.viewport.maxY)
  }

  @Test func revealScrollsTheLastAdvancedRowIntoView() async throws {
    let (context, _) = await SettingsFixture.loaded()
    try await reveal("advanced.licenses", in: .advanced, context: context)
  }

  @Test func revealScrollsTheLastPrivacyRowIntoView() async throws {
    let (_, _, context, _) = await PrivacyPaneTests.make()
    try await reveal("privacy.whatsSent", in: .privacy, context: context)
  }
}

