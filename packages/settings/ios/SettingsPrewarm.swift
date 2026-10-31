import AppKit
import SolaraUI
import SwiftUI

@MainActor
enum SettingsPrewarm {
  static let delay: TimeInterval = 5
  private static var done = false
  private(set) static var warming = false

  static var enabled: Bool { ProcessInfo.processInfo.environment["SOLARA_SETTINGS_PREWARM"] != "0" }

  static func schedule() {
    guard enabled, !done else { return }
    DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
      MainActor.assumeIsolated { RunLoop.main.perform(inModes: [.default]) { MainActor.assumeIsolated { Task { await warm() } } } }
    }
  }

  static func warm() async {
    guard !done, !NativeSettingsWindow.isBuilt, let context = NativeSettingsWindow.makeContext() else { return }
    done = true
    let place = context.navigation.place
    if let provider = context.panes[place.pane], !provider.isLoaded(place) { await provider.prepare(place) }
    guard !NativeSettingsWindow.isBuilt, let controller = NativeSettingsWindow.controller() else { return }
    warming = true
    defer { warming = false }
    let size = NSSize(width: 820, height: 640)
    let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: true)
    window.isReleasedWhenClosed = false
    window.titlebarAppearsTransparent = false
    window.titleVisibility = .visible
    window.contentViewController = controller
    window.setContentSize(size)
    controller.view.layoutSubtreeIfNeeded()
    window.contentViewController = nil
    window.close()
  }
}
