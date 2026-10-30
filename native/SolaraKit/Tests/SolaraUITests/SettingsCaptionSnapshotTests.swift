import AppKit
import SwiftUI
import Testing
@testable import SolaraUI

@MainActor
struct SettingsCaptionSnapshotTests {
  @Test(.enabled(if: Snapshot.directory != nil))
  func rendersDenseRowsAtMinimumAndDefaultWidths() async throws {
    let directory = try #require(Snapshot.directory)
    let (context, _) = await SettingsFixture.loaded()
    for pane in [SettingsPane.tabs, .privacy, .advanced, .general, .appearance, .engines] {
      context.navigation.go(pane)
      context.syncShown()
      for width in [720, 820] {
        for dark in [false, true] {
          let name = "\(pane.rawValue)-\(width)-\(dark ? "dark" : "light").png"
          try await Snapshot.render(SettingsWindowView(context: context), size: NSSize(width: width, height: 2400), dark: dark, to: directory.appendingPathComponent(name))
        }
      }
    }
  }
}
