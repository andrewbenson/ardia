import Foundation
import XCTest

@testable import ArdiaSyncCore

final class PasswordValuesTests: XCTestCase {
  let keys = SyncKeys(entropy: Data(repeating: 7, count: 32))
  let other = SyncKeys(entropy: Data(repeating: 9, count: 32))
  let tricky = #"{"k":"x:\/é🔑\u0001\"","h":"000000001.0000.dev1","v":{"title":"a\u2028b \\ \"q\"","n":1.5e+21,"z":[true,null]}}"#

  func sealed(_ p: String, _ o: String = "https://a.example", _ u: String = "me") throws -> String { try keys.sealPassword(p, origin: o, username: u) }

  func log(_ value: String) -> String {
    #"{"v":1,"kind":"log","device":"dev1","seq":3,"at":5,"ops":[\#(tricky),{"k":"pw:https://a.example\nme","h":"000000002.0000.dev1","v":\#(value)},{"k":"pw:https://a.example\ngone","h":"000000003.0000.dev1","v":null}]}"#
  }

  func testALogFileSealsOnTheWayInAndOpensOnTheWayOutLeavingEveryOtherByte() throws {
    let plain = log(#"{"o":"https://a.example","u":"me","p":"s1.abc \"🔑\""}"#)
    let inJS = try PasswordValues.convert(plain, .folderFile, .seal, keys: keys)
    XCTAssertEqual(inJS, log(#"{"o":"https://a.example","u":"me","s":\#(PasswordText.jsonString(try sealed("s1.abc \"🔑\"")))}"#))
    XCTAssertEqual(try PasswordValues.convert(inJS, .folderFile, .open, keys: keys), plain, "the folder gets back exactly what it had")
  }

  func testASnapshotsRecordsSealAndOpen() throws {
    let snapshot =
      #"{"v":1,"kind":"snapshot","device":"dev1","at":5,"vv":{"dev1":3},"seen":{},"records":{"pw:https://a.example\nme":{"h":"000000002.0000.dev1","v":{"o":"https://a.example","u":"me","p":"hunter2"},"o":["dev1",3]},"x:1":{"h":"000000001.0000.dev1","v":{"p":"not a login"},"o":["dev1",1]}}}"#
    let inJS = try PasswordValues.convert(snapshot, .folderFile, .seal, keys: keys)
    XCTAssertTrue(inJS.contains(#""s":\#(PasswordText.jsonString(try sealed("hunter2")))"#))
    XCTAssertTrue(inJS.contains(#""x:1":{"h":"000000001.0000.dev1","v":{"p":"not a login"}"#), "only pw: keys are touched")
    XCTAssertEqual(try PasswordValues.convert(inJS, .folderFile, .open, keys: keys), snapshot)
  }

  func testTheFolderNeverGetsAPlainPasswordFromJSOrASealThatDoesntOpen() throws {
    XCTAssertThrowsError(try PasswordValues.convert(log(#"{"o":"https://a.example","u":"me","p":"hunter2"}"#), .folderFile, .open, keys: keys))
    let foreign = try other.sealPassword("hunter2", origin: "https://a.example", username: "me")
    XCTAssertThrowsError(try PasswordValues.convert(log(#"{"o":"https://a.example","u":"me","s":\#(PasswordText.jsonString(foreign))}"#), .folderFile, .open, keys: keys))
    let elsewhere = try keys.sealPassword("hunter2", origin: "https://b.example", username: "me")
    XCTAssertThrowsError(try PasswordValues.convert(log(#"{"o":"https://a.example","u":"me","s":\#(PasswordText.jsonString(elsewhere))}"#), .folderFile, .open, keys: keys), "a seal moved to another login doesn't open")
  }

  func state(base: String, noted: String, record: String, outbox: String, held: String, journal: String) -> String {
    #"{"p:abc":{"records":{"pw:https://a.example\nme":{"h":"000000002.0000.dev1","v":\#(record),"o":["dev1",3]},"x:é":{"h":"1","v":"\/kept","o":["dev2",1]}},"base":{"pw:https://a.example\nme":\#(base),"x:é":"\"\\\/kept\""},"unapplied":[],"vv":{},"extra":{},"files":{},"damaged":{},"seq":3,"outbox":[\#(outbox)],"heldOutbox":[\#(held)],"journal":[{"v":1,"kind":"log","device":"dev1","seq":3,"at":5,"ops":[\#(outbox)]}],"seen":{},"joined":true,"snapshotAt":0,"pending":0,"rebuild":{"since":5,"noted":{"pw:":{"pw:https://a.example\nme":\#(noted),"pw:https://a.example\nold":"zz"},"x:":{"x:é":"keep"}}}}}"#
  }

  func testAPreUpgradeStateSealsEveryShapeAndRecomputesItsNotes() throws {
    let plainValue = #"{"o":"https://a.example","u":"me","p":"hunter2"}"#
    let sealedText = PasswordText.jsonString(try sealed("hunter2"))
    let sealedValue = #"{"o":"https://a.example","u":"me","s":\#(sealedText)}"#
    let plainCanonical = PasswordText.canonical(origin: "https://a.example", username: "me", password: "hunter2")
    let sealedCanonical = PasswordText.canonical(origin: "https://a.example", username: "me", sealed: try sealed("hunter2"))
    let op = { (v: String) in #"{"k":"pw:https://a.example\nme","h":"000000002.0000.dev1","v":\#(v)}"# }
    let before = state(
      base: PasswordText.jsonString(plainCanonical), noted: PasswordText.jsonString(PasswordText.notedDigest(plainCanonical)), record: plainValue,
      outbox: op(plainValue), held: op(plainValue), journal: op(plainValue))
    let after = try PasswordValues.convert(before, .state, .seal, keys: keys)
    let expected = state(
      base: PasswordText.jsonString(sealedCanonical), noted: PasswordText.jsonString(PasswordText.notedDigest(sealedCanonical)), record: sealedValue,
      outbox: op(sealedValue), held: op(sealedValue), journal: op(sealedValue))
    XCTAssertEqual(after.replacingOccurrences(of: #""pw:https://a.example\nold":"v1:unmatched""#, with: #""pw:https://a.example\nold":"zz""#), expected)
    XCTAssertTrue(after.contains(#""pw:https://a.example\nold":"v1:unmatched""#), "a note matching no value we hold can't be recomputed and says so")
    XCTAssertFalse(try PasswordValues.plainValues(after, .state))
    XCTAssertTrue(try PasswordValues.plainValues(before, .state))
  }

  func testTheJournalDocumentSealsToo() throws {
    let doc = #"{"journal":{"p:abc":[{"v":1,"kind":"log","device":"dev1","seq":4,"at":5,"ops":[{"k":"pw:https://a.example\nme","h":"1","v":{"o":"https://a.example","u":"me","p":"x"}}]}]}}"#
    let after = try PasswordValues.convert(doc, .journal, .seal, keys: keys)
    XCTAssertEqual(after, doc.replacingOccurrences(of: #""p":"x""#, with: #""s":\#(PasswordText.jsonString(try sealed("x")))"#))
  }

  func testADocumentWithoutPasswordsComesBackByteForByte() throws {
    let doc = #"{"v":1,"kind":"log","device":"dev1","seq":3,"at":5,"ops":[\#(tricky)]}"#
    XCTAssertEqual(try PasswordValues.convert(doc, .folderFile, .seal, keys: keys), doc)
    XCTAssertEqual(try PasswordValues.convert(doc, .folderFile, .open, keys: keys), doc)
  }

  func testTwoLoginsWhoseUsernamesDifferOnlyInNormalizationStayTwo() throws {
    let nfc = "jos\u{e9}"
    let nfd = "jose\u{301}"
    let canonical = { (u: String, p: String) in PasswordText.canonical(origin: "https://a.example", username: u, password: p) }
    let key = { (u: String) in "pw:https://a.example\n\(u)" }
    let doc =
      #"{"s":{"base":{\#(PasswordText.jsonString(key(nfc))):\#(PasswordText.jsonString(canonical(nfc, "one"))),\#(PasswordText.jsonString(key(nfd))):\#(PasswordText.jsonString(canonical(nfd, "two")))},"rebuild":{"noted":{"pw:":{\#(PasswordText.jsonString(key(nfc))):\#(PasswordText.jsonString(PasswordText.notedDigest(canonical(nfc, "one")))),\#(PasswordText.jsonString(key(nfd))):\#(PasswordText.jsonString(PasswordText.notedDigest(canonical(nfd, "two"))))}}}}}"#
    let after = try PasswordValues.convert(doc, .state, .seal, keys: keys)
    for (u, p) in [(nfc, "one"), (nfd, "two")] {
      let sealedCanonical = PasswordText.canonical(origin: "https://a.example", username: u, sealed: try keys.sealPassword(p, origin: "https://a.example", username: u))
      XCTAssertTrue(after.contains(PasswordText.jsonString(sealedCanonical)), "base for \(u.unicodeScalars.count) scalars")
      XCTAssertTrue(after.contains(PasswordText.jsonString(PasswordText.notedDigest(sealedCanonical))), "note for \(u.unicodeScalars.count) scalars")
    }
    XCTAssertFalse(after.contains(PasswordValues.unmatched))
  }
}
