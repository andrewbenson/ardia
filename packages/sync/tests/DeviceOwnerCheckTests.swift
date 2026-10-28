import XCTest
@testable import ArdiaSyncCore

final class DeviceOwnerCheckTests: XCTestCase {
  final class Prompts {
    var asked: [(Bool) -> Void] = []
    func evaluate(_ reason: String, _ done: @escaping (Bool) -> Void) { asked.append(done) }
  }

  func testAnApprovalThatArrivesAfterStopSyncingRevealsNothingAndLeavesNoGrant() {
    let prompts = Prompts()
    let check = DeviceOwnerCheck(evaluate: prompts.evaluate)
    var answers: [Bool] = []
    check.confirm(reason: "show") { answers.append($0) }
    check.revoke()
    prompts.asked[0](true)
    XCTAssertEqual(answers, [false])
    check.confirm(reason: "show") { answers.append($0) }
    XCTAssertEqual(prompts.asked.count, 2)
    XCTAssertEqual(answers, [false])
  }

  func testAnApprovalCoversTheNextRequestWithoutAnotherPrompt() {
    let prompts = Prompts()
    let check = DeviceOwnerCheck(evaluate: prompts.evaluate)
    var answers: [Bool] = []
    check.confirm(reason: "show") { answers.append($0) }
    prompts.asked[0](true)
    check.confirm(reason: "show") { answers.append($0) }
    XCTAssertEqual(prompts.asked.count, 1)
    XCTAssertEqual(answers, [true, true])
  }

  func testRequestsWhileAPromptIsOpenShareItsAnswer() {
    let prompts = Prompts()
    let check = DeviceOwnerCheck(evaluate: prompts.evaluate)
    var answers: [Bool] = []
    check.confirm(reason: "show") { answers.append($0) }
    check.confirm(reason: "copy") { answers.append($0) }
    XCTAssertEqual(prompts.asked.count, 1)
    prompts.asked[0](false)
    XCTAssertEqual(answers, [false, false])
    check.confirm(reason: "show") { answers.append($0) }
    XCTAssertEqual(prompts.asked.count, 2)
  }

  func testRevokingEndsAGrant() {
    let prompts = Prompts()
    let check = DeviceOwnerCheck(evaluate: prompts.evaluate)
    var answers: [Bool] = []
    check.confirm(reason: "show") { answers.append($0) }
    prompts.asked[0](true)
    check.revoke()
    check.confirm(reason: "show") { answers.append($0) }
    XCTAssertEqual(prompts.asked.count, 2)
    XCTAssertEqual(answers, [true])
  }

  func testAnApprovalForAPhraseThatChangedDuringThePromptRevealsNothing() {
    let prompts = Prompts()
    let check = DeviceOwnerCheck(evaluate: prompts.evaluate)
    var phrase: String? = "old"
    var revealed: [String?] = []
    check.disclose(reason: "show", current: { phrase }) { revealed.append($0) }
    phrase = "new"
    prompts.asked[0](true)
    XCTAssertEqual(revealed, [nil])
  }

  func testAnApprovalHandsOverThePhraseItWasAskedFor() {
    let prompts = Prompts()
    let check = DeviceOwnerCheck(evaluate: prompts.evaluate)
    var phrase: String? = "old"
    var revealed: [String?] = []
    check.disclose(reason: "show", current: { phrase }) { revealed.append($0) }
    prompts.asked[0](true)
    check.disclose(reason: "show", current: { phrase }) { revealed.append($0) }
    phrase = nil
    check.disclose(reason: "show", current: { phrase }) { revealed.append($0) }
    XCTAssertEqual(revealed, ["old", "old", nil])
    XCTAssertEqual(prompts.asked.count, 1)
  }
}
