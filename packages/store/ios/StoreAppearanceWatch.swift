import AppKit
internal import SolaraStore

@MainActor
enum StoreAppearanceWatch {
  static var observation: NSKeyValueObservation?

  static func start() {
    guard NativeStore.ownsWorkspace, observation == nil else { return }
    observation = NSApp.observe(\.effectiveAppearance, options: [.initial, .new]) { _, _ in
      MainActor.assumeIsolated { publish() }
    }
  }

  static func publish() {
    guard let store = NativeStore.shared?.bridge.store else { return }
    let dark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    do {
      try store.dispatch(Command("setAppDark", [.bool(dark)]))
    } catch {
      NSLog("[store] appearance update failed: %@", "\(error)")
    }
  }
}
