import XCTest
@testable import ArdiaSyncCore

final class DevKeyStoreTests: XCTestCase {
  func testOwnerBuildKeepsItsService() {
    XCTAssertEqual(KeychainKeyStore.service(info: ["CFBundleName": "Solara", "ACDevBuild": ""]), "Solara Sync Key")
    XCTAssertEqual(KeychainKeyStore.service(info: ["CFBundleName": "Solara"]), "Solara Sync Key")
  }

  func testDevBuildNeverUsesTheOwnersService() {
    XCTAssertEqual(KeychainKeyStore.service(info: ["CFBundleName": "Solara", "ACDevBuild": "YES"]), "Solara Dev Sync Key")
  }
}
