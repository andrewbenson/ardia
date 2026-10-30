import Testing
@testable import SolaraUI

@MainActor
struct SafeProfileEditsTests {
  @Test(arguments: ["name", "icon", "preset", "theme", "arc", "order"])
  func safeProfileEditsExplainRefusalBeforeChangingTheSettingsModel(action: String) {
    let store = FakeSettingsStore()
    let services = FakeProfilesServices(store: store)
    let model = ProfilesPaneModel(services: services, store: store, safeMode: true)
    let before = services.profiles
    switch action {
    case "name": #expect(model.updateName("work", "Renamed") == "Work")
    case "icon": model.setIcon("work", "star")
    case "preset": model.choosePreset("work", .green)
    case "theme": model.changeTheme("work", ProfilesFixture.withDarkLook, settle: false)
    case "arc": model.importArcTheme("work", ArcThemeChoice(id: "arc", name: "Arc", theme: ProfilesFixture.withDarkLook))
    default: model.move("work", to: 0)
    }
    #expect(services.profiles == before)
    #expect(services.calls.isEmpty)
    #expect(model.themeDrafts.isEmpty)
    #expect(model.pendingThemes.isEmpty)
    #expect(model.deletePrompt?.title == "Safe Mode")
    #expect(model.deletePrompt?.canDelete == false)
    #expect(model.deletePrompt?.message.contains("saved session") == true)
    #expect(model.deletePrompt?.message.contains("normally") == true)
  }
}
