import Foundation

enum SafeLaunchDocuments {
  private static let safeWrites: Set<String> = [
    "downloads.json", "live.json", "onboarding.json", "release-notes.json", "ardia-cli.json", "dev-eval-result.json", "dev-console.log", "js-errors.log", "js-errors.1.log", "layout-watch.json",
  ]

  static func mayWrite(_ name: String, safeMode: Bool) -> Bool {
    !safeMode || safeWrites.contains(name)
  }

  static func mayRemove(_ name: String, safeMode: Bool) -> Bool {
    !safeMode
  }
}
