import Foundation
import SolaraModel
import SolaraStore
import Testing
@testable import SolaraUI

@MainActor
struct SafeProfileDeletionTests {
  @Test func safeModeRejectsTheProfileDeletionCommandBeforeChangingState() throws {
    var config = StoreConfig()
    config.safeMode = true
    let seed = Store(checksInvariants: false)
    let id = try #require(try seed.dispatch(Command("createProfile", [["name": "Work"]])).result?.string)
    let store = Store(state: seed.state, config: config, checksInvariants: false)
    let before = store.state
    let rev = store.rev
    var message: String?
    do {
      try store.dispatch(Command("deleteProfile", [.string(id)]))
    } catch {
      message = String(describing: error)
    }
    #expect(message == "Profiles can't be deleted in safe mode. Quit and open Solara normally to delete one.")
    #expect(store.state == before)
    #expect(store.rev == rev)
    #expect(store.state.orphanedProfileData.isEmpty)
    let normal = Store(state: before, checksInvariants: false)
    try normal.dispatch(Command("deleteProfile", [.string(id)]))
    #expect(normal.state.profiles[id] == nil)
    #expect(!normal.state.orphanedProfileData.isEmpty)
  }

  @Test func safeModeExplainsWhyTheProfileCannotBeDeleted() async throws {
    let store = FakeSettingsStore()
    let services = FakeProfilesServices(store: store)
    let model = ProfilesPaneModel(services: services, store: store, safeMode: true)
    await model.requestDelete("work", fromDetails: true)
    let prompt = try #require(model.deletePrompt)
    #expect(prompt.message == "Profiles can't be deleted in safe mode. Quit and open Solara normally to delete one.")
    model.confirmDelete(prompt, navigation: nil)
    #expect(model.profile("work") != nil)
    #expect(services.calls.isEmpty)
    let (normal, _, _) = ProfilesPaneTests().make()
    await normal.requestDelete("work", fromDetails: true)
    normal.confirmDelete(try #require(normal.deletePrompt), navigation: nil)
    #expect(normal.profile("work") == nil)
  }
}
