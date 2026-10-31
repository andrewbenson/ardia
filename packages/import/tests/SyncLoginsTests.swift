import Foundation
import SQLite3
import XCTest
@testable import SolaraLegacyImportCore

final class SyncLoginsTests: XCTestCase {
  let chrome = Fixtures.support("Google/Chrome/Default")

  func copiedProfile() throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sync-logins-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    for name in ["Login Data", "Login Data For Account"] {
      let from = chrome.appendingPathComponent(name)
      if FileManager.default.fileExists(atPath: from.path) { try FileManager.default.copyItem(at: from, to: dir.appendingPathComponent(name)) }
    }
    addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
    return dir
  }

  func run(_ file: URL, _ sql: String) {
    var db: OpaquePointer?
    XCTAssertEqual(sqlite3_open(file.path, &db), SQLITE_OK)
    XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK, String(cString: sqlite3_errmsg(db)))
    sqlite3_close(db)
  }

  func testSyncReadMatchesTheImportReadAndHasNoMarkByDefault() throws {
    let read = try ChromiumSecrets.loginsForSync(profile: chrome, key: Fixtures.chromiumKey)
    let plain = try ChromiumSecrets.logins(profile: chrome, key: Fixtures.chromiumKey)
    XCTAssertEqual(read.logins.map(\.credential), plain.items)
    XCTAssertEqual(read.undecryptable, plain.undecryptable)
    XCTAssertNil(read.mark)
  }

  func testMarkAndModifiedComeFromTheSameReadOfLoginData() throws {
    let profile = try copiedProfile()
    let micros = (Int64(1_793_000_000_123) + 11_644_473_600_000) * 1000 + 999
    run(profile.appendingPathComponent("Login Data"), """
      CREATE TABLE IF NOT EXISTS meta(key LONGVARCHAR NOT NULL UNIQUE PRIMARY KEY, value LONGVARCHAR);
      INSERT OR REPLACE INTO meta(key, value) VALUES('solara_sync_ledger', '3@1793000000123');
      UPDATE logins SET date_password_modified = \(micros) WHERE username_value = 'alex' AND origin_url LIKE 'https://shop.example%';
      """)
    let read = try ChromiumSecrets.loginsForSync(profile: profile, key: Fixtures.chromiumKey)
    XCTAssertEqual(read.mark, "3@1793000000123")
    let shop = read.logins.first { $0.credential.url.hasPrefix("https://shop.example") }
    XCTAssertEqual(shop?.modified, 1_793_000_000_123, "floored to the millisecond, never rounded up")
  }

  func testAMarkInTheAccountStoreIsIgnored() throws {
    let profile = try copiedProfile()
    let account = profile.appendingPathComponent("Login Data For Account")
    try XCTSkipUnless(FileManager.default.fileExists(atPath: account.path))
    run(account, """
      CREATE TABLE IF NOT EXISTS meta(key LONGVARCHAR NOT NULL UNIQUE PRIMARY KEY, value LONGVARCHAR);
      INSERT OR REPLACE INTO meta(key, value) VALUES('solara_sync_ledger', '9@1');
      """)
    XCTAssertNil(try ChromiumSecrets.loginsForSync(profile: profile, key: Fixtures.chromiumKey).mark)
  }

  func testUnixMillisFloors() {
    XCTAssertEqual(ChromiumSecrets.unixMillis(webKitMicros: (11_644_473_600_000 + 5) * 1000 + 999), 5)
    XCTAssertNil(ChromiumSecrets.unixMillis(webKitMicros: 0))
  }
}
