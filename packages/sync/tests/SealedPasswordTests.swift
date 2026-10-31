import Foundation
import XCTest

@testable import SolaraLegacySyncCore

final class SealedPasswordTests: XCTestCase {
  let keys = SyncKeys(entropy: Data(repeating: 7, count: 32))
  let other = SyncKeys(entropy: Data(repeating: 8, count: 32))

  func fixture(_ name: String) throws -> [[String: Any]] {
    let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("fixtures/\(name)")
    let data = try (Data(contentsOf: url) as NSData).decompressed(using: .zlib) as Data
    return (try JSONSerialization.jsonObject(with: data) as? [String: Any])?["cases"] as? [[String: Any]] ?? []
  }

  func testEveryValueIsWrittenAsJSWritesIt() throws {
    let cases = try fixture("seal-cases.json.deflate")
    XCTAssertGreaterThanOrEqual(cases.count, 4000)
    var bad = 0
    for item in cases {
      let units = item["units"] as! [String: [Int]]
      let input = units.mapValues { String(decoding: $0.map(UInt16.init), as: UTF16.self) }
      let output = item["output"] as! [String: Any]
      let (o, u, p, s) = (input["o"]!, input["u"]!, input["p"]!, input["s"]!)
      let strings = [o, u, p, s, input["extra"]!].map(PasswordText.jsonString)
      let got: [String] = [
        strings.joined(separator: "\u{1}"), PasswordText.canonical(origin: o, username: u, password: p),
        PasswordText.canonical(origin: o, username: u, sealed: s),
        PasswordText.notedDigest(PasswordText.canonical(origin: o, username: u, password: p)),
        PasswordText.notedDigest(PasswordText.canonical(origin: o, username: u, sealed: s)), PasswordText.ledgerDigest(origin: o, username: u, last: p),
      ]
      let expected: [String] = [
        (output["strings"] as! [String]).joined(separator: "\u{1}"), output["canonicalPlain"] as! String, output["canonicalSealed"] as! String,
        output["notedPlain"] as! String, output["notedSealed"] as! String, output["ledgerPlain"] as! String,
      ]
      if got != expected {
        bad += 1
        if bad <= 3, let i = (0..<got.count).first(where: { got[$0] != expected[$0] }) { XCTFail("field \(i)\n  js:    \(expected[i].debugDescription)\n  swift: \(got[i].debugDescription)") }
      }
    }
    XCTAssertEqual(bad, 0)
  }

  func testTheSealIsDeterministicPerLoginAndOpensOnlyForItsLogin() throws {
    let a = try keys.sealPassword("hunter2", origin: "https://a.example", username: "me")
    XCTAssertEqual(a, try keys.sealPassword("hunter2", origin: "https://a.example", username: "me"))
    XCTAssertNotEqual(a, try keys.sealPassword("hunter2", origin: "https://a.example", username: "you"))
    XCTAssertNotEqual(a, try other.sealPassword("hunter2", origin: "https://a.example", username: "me"))
    XCTAssertEqual(try keys.openPassword(a, origin: "https://a.example", username: "me"), "hunter2")
    XCTAssertThrowsError(try keys.openPassword(a, origin: "https://a.example", username: "you"))
    XCTAssertThrowsError(try other.openPassword(a, origin: "https://a.example", username: "me"))
  }

  func testUsernameAndOriginSplitsDontShareASeal() throws {
    let one = try keys.sealPassword("c", origin: "https://a.example", username: "a\u{0}b")
    let two = try keys.sealPassword("b\u{0}c", origin: "https://a.example", username: "a")
    XCTAssertNotEqual(Data(base64Encoded: one)!.dropFirst().prefix(12), Data(base64Encoded: two)!.dropFirst().prefix(12), "no nonce reuse across splits")
  }

  func testLengthLeaksOnlyItsBucket() throws {
    let sizes = try (0...31).map { try Data(base64Encoded: keys.sealPassword(String(repeating: "x", count: $0), origin: "https://a.example", username: "me"))!.count }
    XCTAssertEqual(Set(sizes.prefix(28)).count, 1)
    XCTAssertEqual(sizes.last, try Data(base64Encoded: keys.sealPassword(String(repeating: "x", count: 59), origin: "https://a.example", username: "me"))!.count)
  }

  func testAPasswordThatLooksSealedRoundTrips() throws {
    for password in ["s1.abc", "AQAAAA==", "", "🔑 Ünï"] {
      let sealed = try keys.sealPassword(password, origin: "https://a.example", username: "me")
      XCTAssertEqual(try keys.openPassword(sealed, origin: "https://a.example", username: "me"), password)
    }
  }
}
