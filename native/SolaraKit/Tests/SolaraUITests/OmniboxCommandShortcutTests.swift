import XCTest
import SolaraModel
@testable import SolaraUI

final class OmniboxCommandShortcutTests: XCTestCase {
  func testCatalogReservationsAndMissingRegistry() {
    var state = BrowserState()
    XCTAssertEqual(CommandShortcutSnapshot().hint("newTab", state: state), "⌘T")
    XCTAssertNil(CommandShortcutSnapshot(menu: []).hint("newTab", state: state))
    XCTAssertNil(CommandShortcutSnapshot().hint("togglePin:row", state: state))
    state.settings["shortcuts"] = ["openExtension:example": ["t", "command"]]
    XCTAssertNil(CommandShortcutSnapshot().hint("newTab", state: state))
    XCTAssertEqual(CommandShortcutSnapshot().hint("openExtension:example", state: state), "⌘T")
  }

  func testFixedSourcesAndAliases() {
    var state = BrowserState()
    state.settings["shortcuts"] = ["newTab": ["A", "command"], "std:copy:": ["k", "command"]]
    let snapshot = CommandShortcutSnapshot(menu: [
      CommandMenuShortcut(id: "newTab"),
      CommandMenuShortcut(id: "std:copy:", defaultKey: "c", defaultModifiers: ["command"], remappable: false, aliases: [["c", "command"], ["x", "command"]]),
    ])
    XCTAssertEqual(snapshot.hint("newTab", state: state), "⇧⌘A")
    XCTAssertEqual(snapshot.hint("std:copy:", state: state), "⌘C")
  }

  func testClearingAndAliasFallback() {
    var state = BrowserState()
    state.settings["shortcuts"] = ["newTab": [], "openExtension:example": ["l", "command"]]
    XCTAssertNil(CommandShortcutSnapshot().hint("newTab", state: state))
    XCTAssertEqual(CommandShortcutSnapshot().hint("focusCommandBar", state: state), "⌃F5")
    XCTAssertEqual(CommandShortcutSnapshot(menu: [CommandMenuShortcut(id: "focusCommandBar")]).hint("focusCommandBar", state: state), "⌘L")
  }

  func testComposedAndDecomposedProfileIdentity() {
    var state = BrowserState()
    state.profileOrder = ["é", "e\u{301}"]
    state.settings["shortcuts"] = ["switchProfile:é": ["x", "command"]]
    XCTAssertEqual(CommandShortcutSnapshot().hint("switchProfile:é", state: state), "⌘X")
    XCTAssertEqual(CommandShortcutSnapshot().hint("switchProfile:e\u{301}", state: state), "⌃2")
  }

  func testProfilePositionsAndFunctionKeys() {
    var state = BrowserState()
    state.profileOrder = (1...10).map { "p\($0)" }
    XCTAssertEqual(CommandShortcutSnapshot().hint("switchProfile:p1", state: state), "⌃1")
    XCTAssertEqual(CommandShortcutSnapshot().hint("switchProfile:p9", state: state), "⌃9")
    XCTAssertNil(CommandShortcutSnapshot().hint("switchProfile:p10", state: state))
    state.settings["shortcuts"] = ["newTab": ["\u{F70F}", "function", "control"]]
    XCTAssertEqual(CommandShortcutSnapshot().hint("newTab", state: state), "⌃🌐F12")
  }
}
