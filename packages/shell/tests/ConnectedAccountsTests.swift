import XCTest
@testable import SolaraShellCore

final class ConnectedAccountsTests: XCTestCase {
  func testOwnerBuildKeepsItsService() {
    XCTAssertEqual(ConnectedAccounts.keychainService(info: ["CFBundleName": "Solara", "ACDevBuild": ""]), "Solara Connected Accounts")
    XCTAssertEqual(ConnectedAccounts.keychainService(info: ["CFBundleName": "Solara"]), "Solara Connected Accounts")
  }

  func testDevBuildNeverUsesTheOwnersService() {
    XCTAssertEqual(ConnectedAccounts.keychainService(info: ["CFBundleName": "Solara", "ACDevBuild": "YES"]), "Solara Dev Connected Accounts")
  }
}
