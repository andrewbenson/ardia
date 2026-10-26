import AppKit
import SwiftUI
import Testing
@testable import SolaraUI

@MainActor
struct OnboardingSnapshotTests {
  static let size = NSSize(width: 1360, height: 860)

  static func render(_ view: some View, _ name: String, size: NSSize = size) async throws {
    guard let directory = Snapshot.directory else { return }
    for dark in [false, true] {
      try await Snapshot.render(
        view.environment(\.onboardingSettled, true).environment(\.onboardingPreviewClock, 0),
        size: size, dark: dark,
        to: directory.appendingPathComponent("\(name)-\(dark ? "dark" : "light").png")
      )
    }
  }

  @Test(.enabled(if: Snapshot.directory != nil))
  func rendersPreviewGallery() async throws {
    for index in 0..<PreviewGallery.framePages {
      try await Self.render(PreviewGalleryPage(page: .frames(index, addressInSidebar: false)), "gallery-frames-\(index)")
    }
    try await Self.render(PreviewGalleryPage(page: .frames(0, addressInSidebar: true)), "gallery-frames-0-field")
    try await Self.render(PreviewGalleryPage(page: .frames(1, addressInSidebar: true)), "gallery-frames-1-field")
    for index in PreviewGallery.mockPages.indices {
      try await Self.render(PreviewGalleryPage(page: .mocks(index)), "gallery-mocks-\(index)")
    }
  }
}
