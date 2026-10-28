import Foundation
import Testing
@testable import SolaraUI

@Suite struct PanePromptSpecsTests {
  private func take(_ page: inout PanePromptPage, _ name: String, _ payload: [String: Any]) -> Bool { page.take(name, payload) }
  private let save: [String: Any] = ["state": "save", "origin": "https://www.example.com", "username": "ada", "passwordLength": 20, "federation": "", "usernames": ["ada"]]

  @Test func savedPromptsAreNotShown() {
    #expect(PanePasswordPrompt(["state": "saved", "origin": "https://a.test"]) == nil)
    #expect(PanePasswordPrompt(save)?.update == false)
  }

  @Test func aNewPageDropsThePrompt() {
    var page = PanePromptPage()
    _ = take(&page, "onNavigationChange", ["url": "https://www.example.com/login"])
    #expect(take(&page, "onPasswordPrompt", save))
    #expect(!take(&page, "onNavigationChange", ["url": "https://www.example.com/login#done"]))
    #expect(page.password != nil)
    #expect(take(&page, "onNavigationChange", ["url": "https://www.example.com/home"]))
    #expect(page.password == nil)
  }

  @Test func saveSpecMatchesRN() {
    let spec = PanePromptSpecs.password(PanePasswordPrompt(save)!, chosen: nil)
    #expect(spec["title"] as? String == "Save password for example.com?")
    #expect(spec["message"] as? String == "That way, it'll be auto-filled next time")
    #expect((spec["buttons"] as? [[String: Any]])?.compactMap { $0["id"] as? String } == ["never", "dismiss", "save"])
    let lines = (((spec["details"] as? [[String: Any]])?.first?["sections"] as? [[String: Any]])?.first?["lines"] as? [[String: Any]]) ?? []
    #expect(lines.map { $0["text"] as? String } == ["ada", String(repeating: "•", count: 16)])
    #expect((spec["popover"] as? [String: Any])?["width"] as? Int == 350)
  }

  @Test func updateWithSeveralNamesOffersChoices() {
    var payload = save
    payload["state"] = "update"
    payload["usernames"] = ["ada", "grace"]
    let spec = PanePromptSpecs.password(PanePasswordPrompt(payload)!, chosen: "grace")
    let detail = (spec["details"] as? [[String: Any]])?.first
    #expect(detail?["kind"] as? String == "choices")
    #expect((detail?["choices"] as? [[String: Any]])?.filter { $0["selected"] as? Bool == true }.compactMap { $0["id"] as? String } == ["grace"])
    #expect((spec["buttons"] as? [[String: Any]])?.compactMap { $0["id"] as? String } == ["nope", "update"])
    #expect(spec["title"] as? String == "Update saved password?")
  }

  private func allow(_ input: inout PromptInputGuard, _ now: TimeInterval, _ activatedAt: TimeInterval) -> Bool { input.allow(at: now, activatedAt: activatedAt) }

  @Test func guardWaitsForTheOpenAndForDoubleInput() {
    var input = PromptInputGuard()
    #expect(!allow(&input, 10, 0))
    input.shown(at: 10)
    #expect(!allow(&input, 10.4, 0))
    #expect(allow(&input, 11, 0))
    #expect(!allow(&input, 11.2, 0))
    #expect(!allow(&input, 12, 11.8))
  }
}
