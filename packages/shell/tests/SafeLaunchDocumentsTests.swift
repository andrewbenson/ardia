import XCTest
@testable import ArdiaShellCore

final class SafeLaunchDocumentsTests: XCTestCase {
  func testSafeLaunchPreservesSavedDocuments() {
    for name in ["session.json", "bookmarks-cache.json", "history.json", "favicons.json", "sync-state-local.nns", "launch-look.json", "cli.json", "new-document.json", "js-errors.previous.log", "foo.json", "foo.log", "other-result.json", "dev-eval-result.json.backup", "../dev-eval-result.json"] {
      XCTAssertFalse(SafeLaunchDocuments.mayWrite(name, safeMode: true), name)
      XCTAssertFalse(SafeLaunchDocuments.mayRemove(name, safeMode: true), name)
    }
    XCTAssertTrue(SafeLaunchDocuments.mayWrite("downloads.json", safeMode: true))
    XCTAssertFalse(SafeLaunchDocuments.mayRemove("downloads.json", safeMode: true))
  }

  func testSafeLaunchAllowsUserDocuments() {
    for name in ["live.json", "onboarding.json", "release-notes.json", "ardia-cli.json"] {
      XCTAssertTrue(SafeLaunchDocuments.mayWrite(name, safeMode: true), name)
      XCTAssertFalse(SafeLaunchDocuments.mayRemove(name, safeMode: true), name)
    }
  }

  func testSafeLaunchAllowsOnlyNamedDiagnosticWrites() {
    for name in ["dev-eval-result.json", "dev-console.log", "js-errors.log", "js-errors.1.log", "layout-watch.json"] {
      XCTAssertTrue(SafeLaunchDocuments.mayWrite(name, safeMode: true), name)
      XCTAssertFalse(SafeLaunchDocuments.mayRemove(name, safeMode: true), name)
    }
  }

  func testNormalLaunchRetainsDocumentWritesAndRemoval() {
    for name in ["session.json", "downloads.json", "onboarding.json", "sync-state-local.nns"] {
      XCTAssertTrue(SafeLaunchDocuments.mayWrite(name, safeMode: false), name)
      XCTAssertTrue(SafeLaunchDocuments.mayRemove(name, safeMode: false), name)
    }
  }
}
