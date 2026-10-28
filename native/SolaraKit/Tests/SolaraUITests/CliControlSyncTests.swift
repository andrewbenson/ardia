import Testing
@testable import SolaraUI

@Suite struct CliControlSyncTests {
  @Test func aFailureFromASupersededEnableDoesNotTurnOffANewerRetry() {
    var sync = CliControlSync()
    let initial = sync.settingChanged(false)!
    #expect(initial.call == .status)
    var off = sync.settled(initial.request, CliControlServer(state: "off", generation: 0), settingOn: false)
    #expect(!off)

    let first = sync.settingChanged(true)!
    let stop = sync.settingChanged(false)!
    off = sync.settled(stop.request, CliControlServer(state: "off", generation: 1), settingOn: false)
    #expect(!off)
    let retry = sync.settingChanged(true)!
    #expect([first.call, stop.call, retry.call] == [.set(true), .set(false), .set(true)])
    off = sync.settled(retry.request, CliControlServer(state: "starting", generation: 2), settingOn: true)
    #expect(!off)

    let failed = CliControlServer(state: "off", generation: 1, reason: "Couldn't listen on 127.0.0.1.")
    off = sync.settled(first.request, failed, settingOn: true)
    #expect(!off)
    off = sync.event(failed, settingOn: true)
    #expect(!off)
    #expect(sync.server?.generation == 2)
  }

  @Test func aFailureOfTheCurrentStartTurnsTheSettingOffAndKeepsTheReason() {
    var sync = CliControlSync()
    let start = sync.settingChanged(true)!
    var off = sync.settled(start.request, CliControlServer(state: "starting", generation: 2), settingOn: true)
    #expect(!off)
    off = sync.event(CliControlServer(state: "off", generation: 2, reason: "Couldn't write ArdiaControl.json: is a directory"), settingOn: true)
    #expect(off)
    #expect(sync.server?.reason?.contains("is a directory") == true)
    let next = sync.settingChanged(false)
    #expect(next?.call == .set(false))
  }

  @Test func eventsWhileARequestIsInFlightNeverTurnTheSettingOff() {
    var sync = CliControlSync()
    _ = sync.settingChanged(true)
    let off = sync.event(CliControlServer(state: "off", generation: 1, reason: "stopped"), settingOn: true)
    #expect(!off)
  }

  @Test func turningControlOffWithoutAReasonIsNotAFailure() {
    var sync = CliControlSync()
    let start = sync.settingChanged(true)!
    let off = sync.settled(start.request, CliControlServer(state: "off", generation: 1), settingOn: true)
    #expect(!off)
  }

  @Test func theSameSettingTwiceSendsNothing() {
    var sync = CliControlSync()
    _ = sync.settingChanged(true)
    let again = sync.settingChanged(true)
    #expect(again == nil)
  }
}
