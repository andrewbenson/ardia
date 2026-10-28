import Foundation
import XCTest

@testable import ArdiaSyncCore

final class LedgerMigrationTests: XCTestCase {
  let keys = SyncKeys(entropy: Data(repeating: 7, count: 32))
  let a = "pw:https://a.example\nme"
  let b = "pw:https://b.example\nyou"
  let c = "pw:https://c.example\nthem"

  func login(_ o: String, _ u: String, _ p: String) -> LedgerMigration.Login { .init(origin: o, username: u, password: p) }
  func v1(_ l: LedgerMigration.Login) -> String { PasswordText.ledgerDigest(origin: l.origin, username: l.username, last: l.password) }
  func v2(_ l: LedgerMigration.Login) throws -> String {
    PasswordText.ledgerDigest(origin: l.origin, username: l.username, last: try keys.sealPassword(l.password, origin: l.origin, username: l.username))
  }

  func ledger(_ dA: String, _ dB: String, _ dC: String) -> String {
    #"{"v":1,"profiles":{"default":{"v":1,"L":4,"t":1790000000000,"keys":{"pw:https://a.example\nme":{"d":[\#(PasswordText.jsonString(dA)),"old.1"],"h":"000000002.0000.dev1","m":1790000000000},"pw:https://b.example\nyou":{"d":[\#(PasswordText.jsonString(dB))],"h":null,"m":5},"pw:https://c.example\nthem":{"d":[\#(PasswordText.jsonString(dC))],"h":"000000003.0000.dev2","m":6}},"scope":"folder dev1@5 sync1","held":["pw:https://b.example\nyou"],"gated":{"pw:https://c.example\nthem":1790000000500}}}}"#
  }

  func testAConsistentLedgerMovesToSealedDigestsKeepingEverythingElse() throws {
    let la = login("https://a.example", "me", "one")
    let lb = login("https://b.example", "you", "two")
    let rc = login("https://c.example", "them", "three")
    let text = ledger(v1(la), v1(lb), v1(rc))
    let profiles = ["default": LedgerMigration.Profile(logins: [CodeUnits(a): la, CodeUnits(b): lb], records: [CodeUnits(c): rc])]
    XCTAssertTrue(LedgerMigration.needsMigration(text))
    let out = try XCTUnwrap(try LedgerMigration.migrate(text, profiles: profiles, keys: keys))
    let expected = ledger(try v2(la), try v2(lb), try v2(rc)).replacingOccurrences(of: #""v":1,"profiles""#, with: #""v":2,"profiles""#)
      .replacingOccurrences(of: #","old.1"]"#, with: "]")
    XCTAssertEqual(out, expected, "L, t, h, m, scope, held and gated are kept; d[1...] is dropped")
    XCTAssertFalse(LedgerMigration.needsMigration(out))
  }

  func testAPendingLocalEditMatchesNeitherSideAndStillClaims() throws {
    let edited = login("https://a.example", "me", "edited here")
    let record = login("https://a.example", "me", "one")
    let text = ledger(v1(login("https://a.example", "me", "before the edit")), "x", "y")
    let out = try XCTUnwrap(try LedgerMigration.migrate(text, profiles: ["default": .init(logins: [CodeUnits(a): edited], records: [CodeUnits(a): record])], keys: keys))
    XCTAssertTrue(out.contains(#""pw:https://a.example\nme":{"d":["v1:unmatched"]"#))
  }

  func testUnreadableLoginDataLeavesTheLedgerAsItIs() throws {
    let text = ledger("a", "b", "c")
    XCTAssertNil(try LedgerMigration.migrate(text, profiles: ["default": .init(logins: nil, records: [:])], keys: keys))
    XCTAssertNil(try LedgerMigration.migrate(text, profiles: [:], keys: keys), "a profile we can't read pauses too")
    XCTAssertNil(try LedgerMigration.migrate(#"{"v":2,"profiles":{}}"#, profiles: [:], keys: keys), "only a v1 ledger migrates")
  }

  func testAfterACrashBetweenTheStateAndTheLedgerTheSealedStateStillGivesTheRecords() throws {
    let rc = login("https://c.example", "them", "three")
    let v1State = #"{"p:abc":{"records":{"pw:https://c.example\nthem":{"h":"1","v":{"o":"https://c.example","u":"them","p":"three"},"o":["dev2",1]}}}}"#
    let v2State = try PasswordValues.convert(v1State, .state, .seal, keys: keys)
    XCTAssertEqual(LedgerMigration.records(fromState: v2State, scope: "p:abc", keys: keys), [CodeUnits(c): rc])
    XCTAssertEqual(LedgerMigration.records(fromState: v1State, scope: "p:abc", keys: keys), [CodeUnits(c): rc])
    let out = try XCTUnwrap(try LedgerMigration.migrate(ledger("a", "b", v1(rc)), profiles: ["default": .init(logins: [:], records: [CodeUnits(c): rc])], keys: keys))
    XCTAssertTrue(out.contains(#"{"d":[\#(PasswordText.jsonString(try v2(rc)))]"#))
  }

  func testLoginDataIsKeyedAsJSKeysItWithTheOriginNormalised() {
    let read = LedgerMigration.logins([
      ("https://a.example/", "me", "one"), ("https://a.example/path", "me", "skipped"), ("ftp://b.example", "you", "skipped"), ("https://c.example", "them", "first"),
      ("https://c.example/", "them", "second"),
    ])
    XCTAssertEqual(read, [CodeUnits(a): login("https://a.example", "me", "one"), CodeUnits(c): login("https://c.example", "them", "second")])
  }
}
