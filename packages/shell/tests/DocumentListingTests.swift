import XCTest
@testable import SolaraShellCore

final class DocumentListingTests: XCTestCase {
  func testAWriteThatLandsWhileListingIsListed() {
    var staged: Set<String> = ["sync-state-d-a-1-e-2.nns"]
    var disk = ["sync-state-d-a-1-e-1.nns"]
    let names = DocumentListing.names(
      prefix: "sync-state-d-",
      pending: { DocumentListing.Pending(staged: staged, removing: []) },
      onDisk: {
        disk.append("sync-state-d-a-1-e-2.nns")
        staged.removeAll()
        return disk
      })
    XCTAssertEqual(names, ["sync-state-d-a-1-e-1.nns", "sync-state-d-a-1-e-2.nns"])
  }

  func testStagedRemovedAndLandingFilesAreMerged() {
    let names = DocumentListing.names(
      prefix: "sync-",
      pending: { DocumentListing.Pending(staged: ["sync-new.nns", "sync-again.nns"], removing: ["sync-old.nns", "sync-again.nns"]) },
      onDisk: { ["sync-old.nns", "sync-kept.nns", "sync-kept.nns.sb-1a2b-Xyz", "other.json"] })
    XCTAssertEqual(names, ["sync-again.nns", "sync-kept.nns", "sync-new.nns"])
  }
}
