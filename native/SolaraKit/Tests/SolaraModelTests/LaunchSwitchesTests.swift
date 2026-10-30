import Foundation
import Synchronization
import Testing
@testable import SolaraModel

@Suite struct LaunchSwitchesTests {
  static let defaultOn: Set<LaunchSwitch> = [
    .nativeShell, .nativeTopStrip, .nativeSidePanel,
    .nativeSidebar, .nativeAutoHide, .nativeProfilePager, .shellPanes, .nativePagesPool, .nativePanePrompts, .shellMainTop,
  ]
  static let shippedSurfaces = defaultOn.filter { !$0.storable(distribution: false) && !$0.storable(distribution: true) }

  func scratchDefaults() -> UserDefaults {
    let name = "LaunchSwitchesTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defaults.removePersistentDomain(forName: name)
    return defaults
  }

  func allNeeds(_ name: LaunchSwitch) -> [String: String] {
    name.needs.reduce(into: [:]) { env, need in
      env[need.rawValue] = "1"
      env.merge(allNeeds(need)) { a, _ in a }
    }
  }

  @Test func environmentValuesReadAsTheOldEqualsOneAndNotZeroChecksDid() {
    for name in LaunchSwitch.allCases where !LaunchSwitch.developmentOnly.contains(name) {
      let on = Self.defaultOn.contains(name)
      for (text, expected) in [("", on), ("1", true), ("0", false), ("true", on), ("off", on)] {
        let switches = LaunchSwitches(environment: allNeeds(name).merging([name.rawValue: text]) { _, b in b }, defaults: nil, distribution: false, skipStored: false)
        let old = on ? text != "0" : text == "1"
        #expect(switches.isOn(name, defaultOn: on) == expected, "\(name.rawValue)=\(text)")
        #expect(expected == old, "\(name.rawValue)=\(text)")
      }
      #expect(LaunchSwitches(environment: [:], defaults: nil, distribution: false, skipStored: false).isOn(name, defaultOn: on) == on)
    }
  }

  @Test func theSyncRedesignIsReadOnlyByInstancesWithTheirOwnDataFolderOfBuildsNotSignedForDistribution() {
    let on = ["ARDIA_SYNC_REDESIGN": "1", "ARDIA_DATA_DIR": "/tmp/x"]
    #expect(LaunchSwitches(environment: on, defaults: nil, distribution: false, skipStored: false).isOn(.syncRedesign, defaultOn: false))
    let distributed = LaunchSwitches(environment: on, defaults: nil, distribution: true, skipStored: false)
    #expect(!distributed.isOn(.syncRedesign, defaultOn: false))
    #expect(!distributed.fromEnvironment(.syncRedesign))
    let ownersAdHocBuild = LaunchSwitches(environment: ["ARDIA_SYNC_REDESIGN": "1"], defaults: nil, distribution: false, skipStored: false)
    #expect(!ownersAdHocBuild.isolated)
    #expect(!ownersAdHocBuild.isOn(.syncRedesign, defaultOn: false), "a launch on the real data folder never turns it on")
    #expect(!ownersAdHocBuild.fromEnvironment(.syncRedesign))
    let hiddenOnTheRealFolder = LaunchSwitches(environment: ["ARDIA_SYNC_REDESIGN": "1", "ARDIA_BACKGROUND": "1"], defaults: nil, distribution: false, skipStored: false)
    #expect(hiddenOnTheRealFolder.isolated)
    #expect(!hiddenOnTheRealFolder.isOn(.syncRedesign, defaultOn: false), "a hidden launch that forgot its data folder still opens the real one")
    let emptyDataFolder = LaunchSwitches(environment: ["ARDIA_SYNC_REDESIGN": "1", "ARDIA_DATA_DIR": ""], defaults: nil, distribution: false, skipStored: false)
    #expect(!emptyDataFolder.isOn(.syncRedesign, defaultOn: false), "an empty data folder is the real one, as the host reads it")
  }

  @Test func theSyncRedesignIsNeverStored() {
    let defaults = scratchDefaults()
    defaults.set("1", forKey: "ARDIA_SYNC_REDESIGN")
    for distribution in [false, true] {
      #expect(!LaunchSwitch.syncRedesign.storable(distribution: distribution))
      #expect(!LaunchSwitches(environment: [:], defaults: defaults, distribution: distribution, skipStored: false).isOn(.syncRedesign, defaultOn: false))
      let stored = StoredLaunchSwitches(defaults: scratchDefaults(), distribution: distribution)
      stored.set(.syncRedesign, true)
      #expect(stored.value(.syncRedesign) == nil)
      #expect(!stored.any)
    }
  }

  @Test func theEnvironmentWinsOverAStoredValue() {
    let defaults = scratchDefaults()
    defaults.set("1", forKey: "ARDIA_NATIVE_SHELL")
    let switches = LaunchSwitches(environment: ["ARDIA_NATIVE_SHELL": "0"], defaults: defaults, distribution: false, skipStored: false)
    #expect(!switches.isOn(.nativeShell, defaultOn: false))
    #expect(switches.fromEnvironment(.nativeShell))
    let invalid = LaunchSwitches(environment: ["ARDIA_NATIVE_SHELL": "yes"], defaults: defaults, distribution: false, skipStored: false)
    #expect(invalid.isOn(.nativeShell, defaultOn: false))
    #expect(!invalid.fromEnvironment(.nativeShell))
  }

  @Test func storedValuesCountOnlyAsOneOrZero() {
    let defaults = scratchDefaults()
    defaults.set(true, forKey: "ARDIA_NATIVE_SIDEBAR")
    defaults.set("on", forKey: "ARDIA_SHELL_PANES")
    defaults.set(1, forKey: "ARDIA_NATIVE_TOP_STRIP")
    let switches = LaunchSwitches(environment: [:], defaults: defaults, distribution: false, skipStored: false)
    #expect(switches.isOn(.nativeSidebar, defaultOn: false))
    #expect(!switches.isOn(.shellPanes, defaultOn: false))
    #expect(switches.isOn(.nativeTopStrip, defaultOn: false))
  }

  @Test func anIsolatedInstanceIgnoresStoredValuesAndCannotWriteThem() {
    let defaults = scratchDefaults()
    defaults.set("1", forKey: "ARDIA_NATIVE_SHELL")
    for env in [["ARDIA_BACKGROUND": "1"], ["ARDIA_DATA_DIR": "/tmp/x"]] {
      let switches = LaunchSwitches(environment: env, defaults: defaults, distribution: false, skipStored: false)
      #expect(switches.isolated)
      #expect(!switches.isOn(.nativeShell, defaultOn: false))
      let stored = StoredLaunchSwitches(switches, defaults: defaults)
      #expect(!stored.writable)
      #expect(stored.value(.nativeShell) == nil)
      stored.set(.nativeSidebar, true)
      #expect(defaults.object(forKey: "ARDIA_NATIVE_SIDEBAR") == nil)
    }
  }

  @Test func theKillSwitchTheShippedSurfacesAndTheScopeAreNeverReadFromDefaults() {
    let defaults = scratchDefaults()
    #expect(Self.shippedSurfaces.contains(.nativePanePrompts) && !Self.shippedSurfaces.contains(.nativeShell))
    for name in Self.shippedSurfaces { defaults.set("0", forKey: name.rawValue) }
    defaults.set("settingsAndDownloads", forKey: LaunchSwitches.scopeVariable)
    for distribution in [false, true] {
      let switches = LaunchSwitches(environment: [:], defaults: defaults, distribution: distribution, skipStored: false)
      for name in Self.shippedSurfaces { #expect(switches.isOn(name, defaultOn: true), "\(name.rawValue)") }
      #expect(switches.scope == nil)
    }
  }

  @Test func aDistributionBuildIgnoresStoredValuesForEveryDefaultOnSwitch() {
    let defaults = scratchDefaults()
    for name in LaunchSwitch.onByDefault { defaults.set("0", forKey: name.rawValue) }
    let shipped = LaunchSwitches(environment: [:], defaults: defaults, distribution: true, skipStored: false)
    let dev = LaunchSwitches(environment: [:], defaults: defaults, distribution: false, skipStored: false)
    for name in LaunchSwitch.onByDefault {
      #expect(shipped.isOn(name), "\(name.rawValue)")
      if name.storable(distribution: false) { #expect(!dev.isOn(name), "\(name.rawValue)") }
      #expect(!name.storable(distribution: true))
    }
    let overridden = LaunchSwitches(environment: ["ARDIA_NATIVE_SHELL": "0"], defaults: defaults, distribution: true, skipStored: false)
    #expect(overridden.isOn(.nativeShell))
    let devOverride = LaunchSwitches(environment: ["ARDIA_NATIVE_SHELL": "0"], defaults: defaults, distribution: false, skipStored: false)
    #expect(!devOverride.isOn(.nativeShell))
  }

  @Test func aSafeModeDecisionDoesNotChangeStoredSwitches() {
    let defaults = scratchDefaults()
    defaults.set("0", forKey: "ARDIA_NATIVE_SHELL")
    let held = LaunchSwitches.launching(environment: [:], defaults: defaults, distribution: false, optionHeld: { true })
    #expect(held.safeMode)
    #expect(!held.isOn(.nativeShell))
    #expect(defaults.string(forKey: "ARDIA_NATIVE_SHELL") == "0")
  }

  @Test func writingAndClearingTouchOnlyTheAllowedKeys() {
    let defaults = scratchDefaults()
    defaults.set("1", forKey: "ARDIA_NATIVE_GONE")
    defaults.set("1", forKey: "ARDIA_TEST_REAUTH")
    defaults.set("1", forKey: "ARDIA_SHELL_MAIN_TOP")
    let stored = StoredLaunchSwitches(defaults: defaults, distribution: true)
    stored.set(.nativeShell, true)
    stored.set(.nativePanePrompts, false)
    stored.set(.nativePagesPool, true)
    #expect(defaults.object(forKey: "ARDIA_NATIVE_SHELL") == nil)
    #expect(defaults.object(forKey: "ARDIA_NATIVE_PANE_PROMPTS") == nil)
    #expect(defaults.object(forKey: "ARDIA_NATIVE_PAGES_POOL") == nil)
    #expect(defaults.string(forKey: "ARDIA_NATIVE_GONE") == "1")
    #expect(defaults.string(forKey: "ARDIA_TEST_REAUTH") == "1")
    #expect(!stored.any)
    stored.set(.nativeShell, nil)
    #expect(!stored.any)
    stored.set(.nativeSidebar, false)
    stored.clear()
    #expect(defaults.object(forKey: "ARDIA_NATIVE_GONE") == nil)
    #expect(defaults.object(forKey: "ARDIA_NATIVE_SIDEBAR") == nil)
    #expect(defaults.string(forKey: "ARDIA_SHELL_MAIN_TOP") == "1")
  }

  @Test func dependenciesMatchTheCallSites() {
    #expect(LaunchSwitch.shellPanes.needs == [.nativeShell])
    #expect(LaunchSwitch.nativeAutoHide.needs == [.nativeShell])
    #expect(LaunchSwitch.nativePagesPool.needs == [.nativeShell])
    #expect(LaunchSwitch.shellMainTop.needs == [.shellPanes, .nativePagesPool])
    #expect(LaunchSwitch.nativeSidebar.needs.isEmpty)
    #expect(LaunchSwitch.nativeProfilePager.needs == [.nativeShell, .nativeSidebar, .nativeTopStrip])
    #expect(LaunchSwitch.nativePanePrompts.needs == [.nativeShell, .nativePagesPool])
    #expect(LaunchSwitch.onByDefault == Self.defaultOn)
  }

  @Test func aSwitchWhoseNeedsAreOffStaysOffAndTheLaunchSaysWhy() {
    let alone = LaunchSwitches(environment: ["ARDIA_NATIVE_PROFILE_PAGER": "1", "ARDIA_NATIVE_SHELL": "1", "ARDIA_NATIVE_SIDEBAR": "0"], defaults: nil, distribution: false, skipStored: false)
    #expect(alone.requested(.nativeProfilePager, defaultOn: false))
    #expect(!alone.isOn(.nativeProfilePager, defaultOn: false))
    #expect(alone.unmetNeeds(.nativeProfilePager) == [.nativeSidebar])
    #expect(alone.refusals == [
      "ARDIA_NATIVE_PROFILE_PAGER is on but stays off: it needs ARDIA_NATIVE_SIDEBAR=1",
    ])
    let met = LaunchSwitches(
      environment: ["ARDIA_NATIVE_PROFILE_PAGER": "1", "ARDIA_NATIVE_SHELL": "1", "ARDIA_NATIVE_SIDEBAR": "1"], defaults: nil, distribution: false, skipStored: false)
    #expect(met.isOn(.nativeProfilePager, defaultOn: false))
    #expect(met.refusals.isEmpty)

    let prompts = LaunchSwitches(environment: ["ARDIA_NATIVE_PANE_PROMPTS": "1", "ARDIA_NATIVE_SHELL": "1", "ARDIA_NATIVE_PAGES_POOL": "0"], defaults: nil, distribution: false, skipStored: false)
    #expect(!prompts.isOn(.nativePanePrompts, defaultOn: false))
    #expect(prompts.refusals == [
      "ARDIA_SHELL_MAIN_TOP is on but stays off: it needs ARDIA_NATIVE_PAGES_POOL=1",
      "ARDIA_NATIVE_PANE_PROMPTS is on but stays off: it needs ARDIA_NATIVE_PAGES_POOL=1",
    ])

    let noShell = LaunchSwitches(
      environment: ["ARDIA_NATIVE_SHELL": "0", "ARDIA_SHELL_MAIN_TOP": "1", "ARDIA_SHELL_PANES": "1", "ARDIA_NATIVE_PAGES_POOL": "1"], defaults: nil, distribution: false, skipStored: false)
    #expect(!noShell.isOn(.shellMainTop, defaultOn: false))
    #expect(noShell.unmetNeeds(.shellMainTop) == [.shellPanes, .nativePagesPool])
    #expect(noShell.refusals.count == 6)
    #expect(LaunchSwitches(environment: [:], defaults: nil, distribution: false, skipStored: false).refusals.isEmpty)
    #expect(LaunchSwitches(environment: ["ARDIA_NATIVE_SHELL": "0", "ARDIA_SHELL_PANES": "0", "ARDIA_NATIVE_AUTOHIDE": "0", "ARDIA_NATIVE_PROFILE_PAGER": "0", "ARDIA_NATIVE_PAGES_POOL": "0", "ARDIA_NATIVE_PANE_PROMPTS": "0", "ARDIA_SHELL_MAIN_TOP": "0"], defaults: nil, distribution: false, skipStored: false).refusals.isEmpty)
  }

  @Test func theOneArgumentReadUsesTheSwitchsOwnDefault() {
    let empty = LaunchSwitches(environment: [:], defaults: nil, distribution: false, skipStored: false)
    for name in LaunchSwitch.allCases where !LaunchSwitch.developmentOnly.contains(name) {
      #expect(empty.isOn(name) == (LaunchSwitch.onByDefault.contains(name) && empty.unmetNeeds(name).isEmpty), "\(name.rawValue)")
    }
    let off = LaunchSwitches(environment: LaunchSwitch.onByDefault.reduce(into: [:]) { $0[$1.rawValue] = "0" }, defaults: nil, distribution: false, skipStored: false)
    #expect(LaunchSwitch.onByDefault.allSatisfy { !off.isOn($0) })
  }

  @Test func theNativeInterfaceIsOnByDefaultEvenWithASavedZeroInDistribution() {
    let defaults = scratchDefaults()
    defaults.set("0", forKey: "ARDIA_NATIVE_SHELL")
    let shipped = LaunchSwitches(environment: [:], defaults: defaults, distribution: true, skipStored: false)
    #expect(LaunchSwitch.onByDefault.allSatisfy { shipped.isOn($0) })
    let dev = LaunchSwitches(environment: [:], defaults: defaults, distribution: false, skipStored: false)
    #expect(!dev.isOn(.nativeShell))
  }

  @Test func aSavedSwitchWhoseNeedsWereTurnedOffStaysOff() {
    let defaults = scratchDefaults()
    defaults.set("0", forKey: "ARDIA_NATIVE_SHELL")
    defaults.set("1", forKey: "ARDIA_SHELL_PANES")
    let switches = LaunchSwitches(environment: [:], defaults: defaults, distribution: false, skipStored: false)
    #expect(!switches.isOn(.shellPanes, defaultOn: false))
    #expect(switches.refusals.count == 6)
    defaults.set("1", forKey: "ARDIA_NATIVE_SHELL")
    let withShell = LaunchSwitches(environment: [:], defaults: defaults, distribution: false, skipStored: false)
    #expect(withShell.isOn(.shellPanes, defaultOn: false))
    #expect(withShell.refusals.isEmpty)
  }

  @Test func twoUnfinishedLaunchesTriggerSafeModeWithoutChangingSwitches() {
    for distribution in [false, true] {
      let defaults = scratchDefaults()
      defaults.set("1", forKey: "ARDIA_NATIVE_SIDEBAR")
      let launch = { LaunchSwitches.launching(environment: [:], defaults: defaults, distribution: distribution, optionHeld: { false }) }
      #expect(launch().countedLaunch)
      #expect(defaults.integer(forKey: LaunchSwitches.failedLaunchesKey) == 1)
      #expect(launch().countedLaunch)
      #expect(defaults.integer(forKey: LaunchSwitches.failedLaunchesKey) == 2)
      let third = launch()
      #expect(third.safeMode && third.safeModeAfterFailedLaunches && third.countedLaunch)
      #expect(third.isOn(.nativeShell) && third.isOn(.nativeTopStrip) && third.isOn(.nativeSidebar))
      #expect(defaults.object(forKey: "ARDIA_NATIVE_SHELL") == nil)
      #expect(defaults.string(forKey: "ARDIA_NATIVE_SIDEBAR") == "1")
      #expect(defaults.integer(forKey: LaunchSwitches.failedLaunchesKey) == 2)
      #expect((third.safeModeReport ?? "").contains("twice in a row"))
      let fourth = launch()
      #expect(fourth.safeMode && fourth.safeModeAfterFailedLaunches && fourth.countedLaunch)
      #expect(defaults.integer(forKey: LaunchSwitches.failedLaunchesKey) == 2)
      LaunchSwitches.launchSucceeded(defaults: defaults, isolated: false)
      #expect(defaults.object(forKey: LaunchSwitches.failedLaunchesKey) == nil)
      let fifth = launch()
      #expect(!fifth.safeMode && fifth.countedLaunch)
    }
  }

  @Test func launchesStillCountWhenDevelopmentSwitchesAreStoredOff() {
    let defaults = scratchDefaults()
    for name in LaunchSwitch.experiments { defaults.set("0", forKey: name.rawValue) }
    let launch = { LaunchSwitches.launching(environment: [:], defaults: defaults, distribution: false, optionHeld: { false }) }
    #expect(launch().countedLaunch)
    #expect(launch().countedLaunch)
    #expect(launch().safeMode)
    for name in LaunchSwitch.experiments { #expect(defaults.string(forKey: name.rawValue) == "0") }
  }

  @Test func anIsolatedLaunchNeitherCountsNorAsksForOption() {
    let defaults = scratchDefaults()
    defaults.set("1", forKey: "ARDIA_NATIVE_SHELL")
    var asked = false
    for _ in 0..<3 {
      let switches = LaunchSwitches.launching(environment: ["ARDIA_DATA_DIR": "/tmp/x"], defaults: defaults, distribution: false, optionHeld: { asked = true; return true })
      #expect(!switches.isOn(.nativeShell, defaultOn: false))
    }
    #expect(!asked)
    #expect(defaults.object(forKey: LaunchSwitches.failedLaunchesKey) == nil)
    #expect(defaults.string(forKey: "ARDIA_NATIVE_SHELL") == "1")
  }

  @Test func holdingOptionStartsSafeModeForOneLaunchWithoutWritingSwitches() {
    for distribution in [false, true] {
      let defaults = scratchDefaults()
      defaults.set("1", forKey: "ARDIA_NATIVE_SIDEBAR")
      defaults.set(1, forKey: LaunchSwitches.failedLaunchesKey)
      let held = LaunchSwitches.launching(environment: [:], defaults: defaults, distribution: distribution, optionHeld: { true })
      #expect(held.safeMode && held.countedLaunch && !held.safeModeAfterFailedLaunches)
      #expect(held.isOn(.nativeShell) && held.isOn(.nativeSidebar) && held.isOn(.nativeTopStrip))
      #expect(defaults.object(forKey: "ARDIA_NATIVE_SHELL") == nil)
      #expect(defaults.string(forKey: "ARDIA_NATIVE_SIDEBAR") == "1")
      #expect(defaults.integer(forKey: LaunchSwitches.failedLaunchesKey) == 2)
      let retry = LaunchSwitches.launching(environment: [:], defaults: defaults, distribution: distribution, optionHeld: { false })
      #expect(retry.safeMode && retry.safeModeAfterFailedLaunches && retry.countedLaunch)
      LaunchSwitches.launchSucceeded(defaults: defaults, isolated: false)
      let next = LaunchSwitches.launching(environment: [:], defaults: defaults, distribution: distribution, optionHeld: { false })
      #expect(!next.safeMode && next.isOn(.nativeShell) && next.countedLaunch)
    }
  }

  @Test func holdingOptionAsksFirstAndOpeningNormallyChangesNothing() {
    let defaults = scratchDefaults()
    var asked = 0
    let declined = LaunchSwitches.launching(
      environment: [:], defaults: defaults, distribution: true, optionHeld: { true }, confirmSafeMode: { asked += 1; return false })
    #expect(asked == 1 && !declined.safeMode && declined.countedLaunch)
    #expect(defaults.object(forKey: "ARDIA_NATIVE_SHELL") == nil)
    let accepted = LaunchSwitches.launching(
      environment: [:], defaults: defaults, distribution: true, optionHeld: { true }, confirmSafeMode: { asked += 1; return true })
    #expect(asked == 2 && accepted.safeMode && accepted.isOn(.nativeShell))
    #expect(defaults.object(forKey: "ARDIA_NATIVE_SHELL") == nil)
    let question = LaunchSwitches.safeModeQuestion()
    #expect(question.title == "Open Solara in safe mode?")
    #expect(question.message.contains("saved session") && question.message.contains("extensions"))
  }

  @Test func aScratchSuiteLetsAnIsolatedDevelopmentInstanceStoreAndCount() {
    let defaults = scratchDefaults()
    defaults.set("1", forKey: "ARDIA_NATIVE_SHELL")
    let env = ["ARDIA_BACKGROUND": "1", "ARDIA_DATA_DIR": "/tmp/x", LaunchSwitches.defaultsVariable: "scratch"]
    let switches = LaunchSwitches.launching(environment: env, defaults: defaults, distribution: false, optionHeld: { false })
    #expect(switches.isolated && switches.usesDefaults && switches.defaultsSuite == "scratch")
    #expect(switches.isOn(.nativeShell, defaultOn: false))
    #expect(switches.countedLaunch)
    #expect(StoredLaunchSwitches(switches, defaults: defaults).writable)
    _ = LaunchSwitches.launching(environment: env, defaults: defaults, distribution: false, optionHeld: { false })
    #expect(LaunchSwitches.launching(environment: env, defaults: defaults, distribution: false, optionHeld: { false }).safeModeAfterFailedLaunches)
  }

  @Test func aDistributionBuildRefusesTheScratchSuite() {
    let defaults = scratchDefaults()
    defaults.set("1", forKey: "ARDIA_NATIVE_SHELL")
    let env = ["ARDIA_BACKGROUND": "1", LaunchSwitches.defaultsVariable: "scratch"]
    let switches = LaunchSwitches.launching(environment: env, defaults: defaults, distribution: true, optionHeld: { false })
    #expect(switches.defaultsSuite == nil && !switches.usesDefaults)
    #expect(!switches.isOn(.nativeShell, defaultOn: false))
    #expect(!StoredLaunchSwitches(switches, defaults: defaults).writable)
    #expect(defaults.object(forKey: LaunchSwitches.failedLaunchesKey) == nil)
  }

  @Test func theOptionQuestionIsAskedWithoutHoldingTheSwitchLock() {
    let cell = Mutex<LaunchSwitches?>(nil)
    let defaults = scratchDefaults()
    var lockFreeWhileAsking: [Bool] = []
    var answers: [Bool?] = []
    let build: (Bool?) -> LaunchSwitches = { answer in
      answers.append(answer)
      return LaunchSwitches.launching(
        environment: [:], defaults: defaults, distribution: true, optionHeld: { answer != nil }, confirmSafeMode: { answer ?? false })
    }
    let first = LaunchSwitches.resolve(cell, ask: {
      lockFreeWhileAsking.append(cell.withLockIfAvailable { _ in true } ?? false)
      return true
    }, build: build)
    #expect(lockFreeWhileAsking == [true])
    #expect(answers == [true])
    #expect(first.safeMode && first.isOn(.nativeShell))
    #expect(defaults.object(forKey: "ARDIA_NATIVE_SHELL") == nil)
    let again = LaunchSwitches.resolve(cell, ask: {
      lockFreeWhileAsking.append(false)
      return false
    }, build: build)
    #expect(lockFreeWhileAsking == [true], "once resolved, nothing asks again")
    #expect(again.safeMode && answers.count == 1)
  }
}
