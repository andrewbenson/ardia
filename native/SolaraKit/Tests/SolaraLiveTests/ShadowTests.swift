import Foundation
import Testing

@testable import SolaraLive

@Suite struct ShadowTests {
  @Test func loadsTheJSPersistedFixtureWithoutEffectsAndReloadsAfterASave() async {
    let replay = Fixture.golden["stateReplay"] as! [String: Any]
    let persisted = replay["persisted"] as! String
    let rig = Rig(documents: [LiveState.documentName: persisted])
    let shadow = LiveShadow(effects: rig.engine.effects)

    let first = await shadow.snapshot()
    #expect(first.live.persistedPart == LiveState.load(persisted).persistedPart)
    #expect(first.live.status.isEmpty)
    #expect(first.calendar == CalendarData())
    #expect(rig.documents.writes.current == 0)
    #expect(rig.http.log.current.isEmpty)
    #expect(rig.calendar.asked.current.isEmpty)
    #expect(rig.clock.pending.isEmpty)

    let changed = #"{"calendar":{"alertLead":"5"},"accounts":{"notion":{"login":"me","name":null,"avatar":null,"connectedAt":1}}}"#
    rig.documents.docs.with { $0[LiveState.documentName] = changed }
    await shadow.reload()
    let second = await shadow.snapshot()
    #expect(second.live.calendar.alertLead == "5")
    #expect(second.live.accounts.keys.sorted() == [.notion])
    #expect(second.live.folders.isEmpty)
    #expect(rig.documents.writes.current == 0)
    #expect(rig.http.log.current.isEmpty)
    #expect(rig.calendar.asked.current.isEmpty)
    #expect(rig.clock.pending.isEmpty)
  }
}
