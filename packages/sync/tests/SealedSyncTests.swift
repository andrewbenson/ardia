import Foundation
import XCTest

@testable import ArdiaSyncCore

final class SealedSyncTests: XCTestCase {
  let keys = SyncKeys(entropy: Data(repeating: 7, count: 32))
  let other = SyncKeys(entropy: Data(repeating: 9, count: 32))

  func sealed(_ p: String, _ o: String = "https://a.example", _ u: String = "me", keys: SyncKeys? = nil) throws -> String {
    try (keys ?? self.keys).sealPassword(p, origin: o, username: u)
  }

  func testTheOriginIsNormalisedAsJSOriginOfDoes() {
    XCTAssertEqual(SealedPasswords.origin(of: "https://a.example/"), "https://a.example")
    XCTAssertEqual(SealedPasswords.origin(of: "http://a.example:8080"), "http://a.example:8080")
    XCTAssertEqual(SealedPasswords.origin(of: "https://a.example//"), nil, "only one trailing slash goes")
    XCTAssertEqual(SealedPasswords.origin(of: "https://a.example/path"), nil)
    XCTAssertEqual(SealedPasswords.origin(of: "HTTPS://a.example"), nil)
    XCTAssertEqual(SealedPasswords.origin(of: "https://"), nil)
    XCTAssertEqual(SealedPasswords.origin(of: "android://hash@com.example/"), nil)
    XCTAssertEqual(SealedPasswords.origin(of: "https://a.example\n"), nil, "a trailing newline isn't an end of input, as $ is in NSRegularExpression")
    XCTAssertEqual(SealedPasswords.origin(of: "https://a.example\u{FEFF}"), nil, "JS counts U+FEFF as whitespace")
    XCTAssertEqual(SealedPasswords.origin(of: "https://a\u{A0}b"), nil)
    XCTAssertEqual(SealedPasswords.origin(of: "https://\u{0085}a"), "https://\u{0085}a", "JS doesn't count U+0085 as whitespace")
    XCTAssertEqual(SealedPasswords.origin(of: "https://ü.example/"), "https://ü.example")
  }

  func testOnlyAnExactSealedValueThatOpensPasses() throws {
    XCTAssertTrue(SealedPasswords.opens(["o": "https://a.example", "u": "me", "s": try sealed("one")], keys: keys))
    XCTAssertFalse(SealedPasswords.opens(["o": "https://a.example", "u": "you", "s": try sealed("one")], keys: keys), "bound to its login")
    XCTAssertFalse(SealedPasswords.opens(["o": "https://a.example", "u": "me", "s": try sealed("one", keys: other)], keys: keys), "another chain's key")
    XCTAssertFalse(SealedPasswords.opens(["o": "https://a.example", "u": "me", "p": "one"], keys: keys))
    XCTAssertFalse(SealedPasswords.opens(["o": "https://a.example", "u": "me", "s": try sealed("one"), "p": "one"], keys: keys))
  }

  func testAFolderFileThatCantBeSealedIsReadAsDamagedNotPassedOn() throws {
    let good = #"{"v":1,"kind":"log","device":"d","seq":1,"at":1,"ops":[{"k":"pw:https://a.example\nme","h":"1","v":{"o":"https://a.example","u":"me","p":"one"}}]}"#
    let both = #"{"v":1,"kind":"log","device":"d","seq":2,"at":1,"ops":[{"k":"pw:https://a.example\nme","h":"1","v":{"o":"https://a.example","u":"me","p":"one","s":"x"}}]}"#
    let broken = #"{"v":1,"kind":"log","ops":[{"k":"pw:x","v":{"o":"a","u":"b","p":"one"}"#
    var listing = SyncVault.Listing()
    listing.files = [.init(id: "a", payload: Data(good.utf8)), .init(id: "b", payload: Data(both.utf8)), .init(id: "c", payload: Data(broken.utf8))]
    listing.present = ["a", "b", "c"]
    let read = SealedPasswords.folderListing(listing, keys: keys)
    XCTAssertEqual(read.files.map(\.id), ["a"])
    XCTAssertEqual(String(decoding: read.files[0].payload, as: UTF8.self), good.replacingOccurrences(of: #""p":"one""#, with: #""s":\#(PasswordText.jsonString(try sealed("one")))"#))
    XCTAssertEqual(read.damaged.map(\.id), ["b", "c"])
    XCTAssertEqual(read.present, ["a", "b", "c"])
  }

  func testWritingToTheFolderOpensSealsAndRefusesAnythingElse() throws {
    let file = { (v: String) in #"{"v":1,"kind":"log","device":"d","seq":1,"at":1,"ops":[{"k":"pw:https://a.example\nme","h":"1","v":\#(v)}]}"# }
    XCTAssertEqual(
      try SealedPasswords.folderPayload(file(#"{"o":"https://a.example","u":"me","s":\#(PasswordText.jsonString(try sealed("one")))}"#), keys: keys),
      file(#"{"o":"https://a.example","u":"me","p":"one"}"#))
    XCTAssertThrowsError(try SealedPasswords.folderPayload(file(#"{"o":"https://a.example","u":"me","p":"one"}"#), keys: keys))
    XCTAssertThrowsError(try SealedPasswords.folderPayload(file(#"{"o":"https://a.example","u":"me","s":\#(PasswordText.jsonString(try sealed("one", keys: other)))}"#), keys: keys))
    XCTAssertThrowsError(try SealedPasswords.folderPayload(file(#"{"o":"https://a.example","u":"me","s":"x","x":1,"p":"one"}"#), keys: keys))
  }

  func testThePlainValuesTheWalkerCantSealAreRefusedNotPassedOn() throws {
    let file = { (v: String) in #"{"v":1,"kind":"log","ops":[{"k":"pw:https://a.example\nme","v":\#(v)}]}"# }
    for value in [
      #"{"o":"https://a.example","u":"me","p":"one","p":"two"}"#, #"{"o":"https://a.example","u":"me","p":"one","s":"x"}"#,
      #"{"o":"https://a.example","u":"me","p":"one","extra":1}"#, #"{"o":"https://a.example","u":"me","p":1}"#, #"{"o":1,"u":"me","p":"one"}"#,
    ] {
      XCTAssertThrowsError(try PasswordValues.convert(file(value), .folderFile, .seal, keys: keys), value)
    }
    XCTAssertEqual(try PasswordValues.convert(file(#"{"o":"https://a.example","u":"me"}"#), .folderFile, .seal, keys: keys), file(#"{"o":"https://a.example","u":"me"}"#))
    do {
      _ = try PasswordValues.convert(file(#"{"o":"https://secret-origin.example","u":"secret-user","s":"c2VjcmV0LXNlYWw="}"#), .folderFile, .open, keys: keys)
      XCTFail("a seal that doesn't open is refused")
    } catch {
      XCTAssertEqual("\(error)", "pw: a sealed password that doesn't open", "a refusal names the key's type, never its origin, username or seal")
    }
    let base = #"{"s":{"base":{"pw:https://a.example\nme":"{\"o\":\"https://a.example\",\"p\":\"one\",\"u\":\"me\",\"x\":1}"}}}"#
    XCTAssertThrowsError(try PasswordValues.convert(base, .state, .seal, keys: keys))
  }

  func testTheLocalEnvelopeIsNativesAndRefusesPlainPasswords() throws {
    let state = #"{"s":{"records":{"pw:x":{"h":"1","v":{"o":"https://a.example","u":"me","s":"AQ=="},"o":["d",1]}}}}"#
    let sealedState = try LocalDocuments.seal(state, .state, keys: keys)
    XCTAssertEqual(LocalDocuments.open(sealedState, .state, keys: keys), state)
    XCTAssertNil(LocalDocuments.open(sealedState, .journal, keys: keys), "a state isn't a journal")
    XCTAssertNil(try? keys.open(sealedState, scopeTag: "local", fileId: "state"), "an older build can't open it, and starts fresh")
    XCTAssertThrowsError(try LocalDocuments.seal(state.replacingOccurrences(of: #""s":"AQ==""#, with: #""p":"guess""#), .state, keys: keys), "JS can't get a seal for a guess")
    let plainBase = #"{"s":{"base":{"pw:x":"{\"o\":\"https://a.example\",\"p\":\"guess\",\"u\":\"me\"}"}}}"#
    XCTAssertThrowsError(try LocalDocuments.seal(plainBase, .state, keys: keys), "nor through base")
    let flagInside = #"{"sealedPasswords":1,"body":"{}"}"#
    XCTAssertEqual(LocalDocuments.open(try LocalDocuments.seal(flagInside, .state, keys: keys), .state, keys: keys), flagInside, "a flag inside JS's text is JS's text")
    XCTAssertNil(LocalDocuments.open(try keys.seal(Data(#"{"sealedPasswords":"1","body":"{}"}"#.utf8), scopeTag: "local", fileId: "state.v2"), .state, keys: keys))
  }

  func testADeltaOrBatchFileOpensOnlyAsThePartItWasSealedFor() throws {
    let delta = #"{"s":{"records":{"pw:x":{"h":"1","v":{"o":"https://a.example","u":"me","s":"AQ=="},"o":["d",1]}}}}"#
    let sealedDelta = try LocalDocuments.seal(delta, .state, part: "d.2.e.3", keys: keys)
    XCTAssertEqual(LocalDocuments.open(sealedDelta, .state, part: "d.2.e.3", keys: keys), delta)
    XCTAssertNil(LocalDocuments.open(sealedDelta, .state, part: "d.2.e.4", keys: keys), "not as another g")
    XCTAssertNil(LocalDocuments.open(sealedDelta, .state, part: "d.3.e.3", keys: keys), "not as another compaction")
    XCTAssertNil(LocalDocuments.open(sealedDelta, .state, keys: keys), "not as the full state")
    XCTAssertNil(LocalDocuments.open(try LocalDocuments.seal(delta, .state, keys: keys), .state, part: "d.2.e.3", keys: keys), "and the full state isn't a delta")
    XCTAssertThrowsError(try LocalDocuments.seal(delta.replacingOccurrences(of: #""s":"AQ==""#, with: #""p":"guess""#), .state, part: "d.2.e.3", keys: keys), "a delta with a plain p is refused")
    let plainBase = #"{"s":{"base":{"pw:x":"{\"o\":\"https://a.example\",\"p\":\"guess\",\"u\":\"me\"}"}}}"#
    XCTAssertThrowsError(try LocalDocuments.seal(plainBase, .state, part: "d.2.e.3", keys: keys), "and so is a plain p in a delta's base")
    let batch = #"{"journal":{"s":[{"v":1,"kind":"log","device":"d","seq":1,"at":1,"ops":[{"k":"pw:https://a.example\nme","h":"1","v":{"o":"https://a.example","u":"me","p":"one"}}]}]}}"#
    XCTAssertThrowsError(try LocalDocuments.seal(batch, .journal, part: "b.s.1", keys: keys), "a batch file with a plain p is refused")
    let sealedBatch = try LocalDocuments.seal(batch.replacingOccurrences(of: #""p":"one""#, with: #""s":"AQ==""#), .journal, part: "b.s.1", keys: keys)
    XCTAssertNil(LocalDocuments.open(sealedBatch, .journal, part: "b.t.1", keys: keys), "a batch can't be read as another scope's")
    XCTAssertNil(LocalDocuments.open(sealedBatch, .journal, part: "b.s.2", keys: keys), "or another seq")
  }

  func testTheSavedStatesReservedKeysAndDeltaShapesSealAndOpen() throws {
    let record = #""pw:x":{"h":"1","v":{"o":"https://a.example","u":"me","s":"AQ=="},"o":["d",1]}"#
    let full = #"{"s":{"records":{\#(record)},"base":{},"files":{}},"~n":3,"~epoch":"0a1b","~device":"abc"}"#
    XCTAssertEqual(LocalDocuments.open(try LocalDocuments.seal(full, .state, keys: keys), .state, keys: keys), full)
    let delta = #"{"s":{"records":{\#(record)},"base":{},"files":{},"unapplied":{"~list":{"drop":["pw:y"],"add":["pw:x"]}},"~gone":{"records":["pw:y"],"rest":["pendingSince"]}}}"#
    XCTAssertEqual(LocalDocuments.open(try LocalDocuments.seal(delta, .state, part: "d.abc.3.0a1b.1", keys: keys), .state, part: "d.abc.3.0a1b.1", keys: keys), delta)
    XCTAssertThrowsError(try LocalDocuments.seal(delta.replacingOccurrences(of: #""s":"AQ==""#, with: #""p":"guess""#), .state, part: "d.abc.3.0a1b.1", keys: keys))
    let v1Delta = #"{"s":{"records":{"pw:https://a.example\nme":{"h":"1","v":{"o":"https://a.example","u":"me","p":"one"},"o":["d",1]}},"base":{},"files":{},"~gone":{"records":["pw:y"]}},"~n":3}"#
    let unlatched = try keys.seal(Data(v1Delta.utf8), scopeTag: "local", fileId: LocalDocuments.legacyFileId(part: "d.abc.3.0a1b.1"))
    let seal = PasswordText.jsonString(try sealed("one"))
    XCTAssertEqual(LocalDocuments.open(unlatched, .state, part: "d.abc.3.0a1b.1", keys: keys), v1Delta.replacingOccurrences(of: #""p":"one""#, with: #""s":\#(seal)"#))
  }

  func testAPartSealedBeforeTheLatchOpensSealedAfterIt() throws {
    let v1Delta = #"{"s":{"records":{"pw:https://a.example\nme":{"h":"1","v":{"o":"https://a.example","u":"me","p":"one"},"o":["d",1]}}}}"#
    let unlatched = try keys.seal(Data(v1Delta.utf8), scopeTag: "local", fileId: LocalDocuments.legacyFileId(part: "d.1.e.1"))
    let seal = PasswordText.jsonString(try sealed("one"))
    XCTAssertEqual(LocalDocuments.open(unlatched, .state, part: "d.1.e.1", keys: keys), v1Delta.replacingOccurrences(of: #""p":"one""#, with: #""s":\#(seal)"#))
    XCTAssertNil(LocalDocuments.open(unlatched, .state, part: "d.1.e.2", keys: keys))
    XCTAssertNil(try? keys.open(unlatched, scopeTag: "local", fileId: "state"), "switched off, a delta doesn't open as the full state")
  }

  func testAPreUpgradeDocumentOpensSealed() throws {
    let v1State = #"{"s":{"records":{"pw:https://a.example\nme":{"h":"1","v":{"o":"https://a.example","u":"me","p":"one"},"o":["d",1]}}}}"#
    let v1Journal = #"{"journal":{"s":[{"v":1,"kind":"log","device":"d","seq":1,"at":1,"ops":[{"k":"pw:https://a.example\nme","h":"1","v":{"o":"https://a.example","u":"me","p":"one"}}]}]}}"#
    let seal = PasswordText.jsonString(try sealed("one"))
    XCTAssertEqual(
      LocalDocuments.open(try keys.seal(Data(v1State.utf8), scopeTag: "local", fileId: "state"), .state, keys: keys),
      v1State.replacingOccurrences(of: #""p":"one""#, with: #""s":\#(seal)"#))
    XCTAssertEqual(
      LocalDocuments.open(try keys.seal(Data(v1Journal.utf8), scopeTag: "local", fileId: "state"), .journal, keys: keys),
      v1Journal.replacingOccurrences(of: #""p":"one""#, with: #""s":\#(seal)"#))
    XCTAssertNil(LocalDocuments.open(try other.seal(Data(v1State.utf8), scopeTag: "local", fileId: "state"), .state, keys: keys))
  }
}
