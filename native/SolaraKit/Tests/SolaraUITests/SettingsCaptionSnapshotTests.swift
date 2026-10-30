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

  @Test(.enabled(if: Snapshot.directory != nil))
  func rendersProfileRowHover() async throws {
    let directory = try #require(Snapshot.directory)
    let (context, store) = await SettingsFixture.loaded()
    let services = FakeProfilesServices(store: store)
    let model = ProfilesPaneModel(services: services, store: store)
    let ids = model.order
    for hovered in ids.indices {
      for dark in [false, true] {
        let view = SettingsForm {
          SettingsSection("Profiles") {
            VStack(spacing: 0) {
              ForEach(Array(ids.enumerated()), id: \.element) { index, id in
                if let profile = model.profile(id) {
                  ProfileRow(model: model, profile: profile, first: index == 0, lifted: false, hovered: index == hovered)
                }
              }
            }
          }
        }
        .environment(\.settingsContext, context)
        try await Snapshot.render(view, size: NSSize(width: 560, height: 280), dark: dark, to: directory.appendingPathComponent("profile-hover-\(hovered)-\(dark ? "dark" : "light").png"))
      }
    }
  }
}
