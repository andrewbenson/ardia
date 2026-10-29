import Foundation
import Synchronization
import Testing
@testable import SolaraModel

@Suite struct LaunchSwitchesTests {
  static let defaultOn: Set<LaunchSwitch> = [
    .nativeSettings, .nativeImport, .nativeOnboarding, .nativeNewTab, .nativeOmnibox, .nativeStatusBubble, .nativeStore, .nativePages,
    .nativeShell, .nativeTabPickers, .nativeTopStrip, .nativeDownloadMagnet,
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
    defaults.set("on", forKey: "ARDIA_NATIVE_MEDIA")
    defaults.set(1, forKey: "ARDIA_NATIVE_TOP_STRIP")
    let switches = LaunchSwitches(environment: [:], defaults: defaults, distribution: false, skipStored: false)
    #expect(switches.isOn(.nativeSidebar, defaultOn: false))
    #expect(!switches.isOn(.nativeMedia, defaultOn: false))
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
    #expect(Self.shippedSurfaces.contains(.nativeStore) && !Self.shippedSurfaces.contains(.nativeShell))
    for name in Self.shippedSurfaces { defaults.set("0", forKey: name.rawValue) }
    defaults.set("settingsAndDownloads", forKey: LaunchSwitches.scopeVariable)
    for distribution in [false, true] {
      let switches = LaunchSwitches(environment: [:], defaults: defaults, distribution: distribution, skipStored: false)
      for name in Self.shippedSurfaces { #expect(switches.isOn(name, defaultOn: true), "\(name.rawValue)") }
      #expect(switches.scope == nil)
    }
  }

  @Test func aDistributionBuildTakesOnlyTheSettingsRowsFromDefaults() {
    let defaults = scratchDefaults()
    for name in LaunchSwitch.storedInDevelopment { defaults.set("1", forKey: name.rawValue) }
    let shipped = LaunchSwitches(environment: [:], defaults: defaults, distribution: true, skipStored: false)
    let dev = LaunchSwitches(environment: [:], defaults: defaults, distribution: false, skipStored: false)
    for name in LaunchSwitch.storedInDevelopment {
      #expect(shipped.isOn(name, defaultOn: false) == LaunchSwitch.experiments.contains(name), "\(name.rawValue)")
      #expect(dev.isOn(name, defaultOn: false), "\(name.rawValue)")
    }
    #expect(!LaunchSwitch.experiments.contains(.nativePagesPool))
    #expect(!LaunchSwitch.experiments.contains(.shellMainTop))
  }

  @Test func holdingOptionAtLaunchSkipsStoredValuesAndSaysSo() {
    let defaults = scratchDefaults()
    defaults.set("1", forKey: "ARDIA_NATIVE_SHELL")
    let skipped = LaunchSwitches(environment: ["ARDIA_NATIVE_SIDEBAR": "1"], defaults: defaults, distribution: false, skipStored: true)
    #expect(!skipped.isOn(.nativeShell, defaultOn: false))
    #expect(skipped.isOn(.nativeSidebar, defaultOn: false))
    #expect(skipped.skippedStored)
    let nothingStored = LaunchSwitches(environment: [:], defaults: scratchDefaults(), distribution: false, skipStored: true)
    #expect(!nothingStored.skippedStored)
    let unstorable = scratchDefaults()
    unstorable.set("0", forKey: "ARDIA_NATIVE_STORE")
    #expect(!LaunchSwitches(environment: [:], defaults: unstorable, distribution: false, skipStored: true).skippedStored)
  }

  @Test func writingAndClearingTouchOnlyTheAllowedKeys() {
    let defaults = scratchDefaults()
    defaults.set("1", forKey: "ARDIA_NATIVE_GONE")
    defaults.set("1", forKey: "ARDIA_TEST_REAUTH")
    defaults.set("1", forKey: "ARDIA_SHELL_MAIN_TOP")
    let stored = StoredLaunchSwitches(defaults: defaults, distribution: true)
    stored.set(.nativeShell, true)
    stored.set(.nativeStore, false)
    stored.set(.nativePagesPool, true)
    #expect(defaults.string(forKey: "ARDIA_NATIVE_SHELL") == "1")
    #expect(defaults.object(forKey: "ARDIA_NATIVE_STORE") == nil)
    #expect(defaults.object(forKey: "ARDIA_NATIVE_PAGES_POOL") == nil)
    #expect(defaults.object(forKey: "ARDIA_NATIVE_GONE") == nil)
    #expect(defaults.string(forKey: "ARDIA_TEST_REAUTH") == "1")
    #expect(stored.any)
    stored.set(.nativeShell, nil)
    #expect(!stored.any)
    stored.set(.nativeSidebar, false)
    stored.clear()
    #expect(defaults.object(forKey: "ARDIA_NATIVE_SIDEBAR") == nil)
    #expect(defaults.string(forKey: "ARDIA_SHELL_MAIN_TOP") == "1")
  }

  @Test func dependenciesMatchTheCallSites() {
    #expect(LaunchSwitch.shellPanes.needs == [.nativeShell])
    #expect(LaunchSwitch.nativeAutoHide.needs == [.nativeShell])
    #expect(LaunchSwitch.nativePagesPool.needs == [.nativeShell])
    #expect(LaunchSwitch.shellMainTop.needs == [.shellPanes, .nativePagesPool])
    #expect(LaunchSwitch.nativeSidebar.needs.isEmpty)
    #expect(LaunchSwitch.nativeTabPickers.needs == [.nativeShell])
    #expect(LaunchSwitch.nativeProfilePager.needs == [.nativeShell, .nativeSidebar, .nativeTopStrip])
    #expect(LaunchSwitch.nativeIconPicker.needs == [.nativeShell, .nativeSidebar])
    #expect(LaunchSwitch.nativePanePrompts.needs == [.nativeShell, .nativePagesPool])
    #expect(LaunchSwitch.onByDefault == Self.defaultOn)
  }

  @Test func aSwitchWhoseNeedsAreOffStaysOffAndTheLaunchSaysWhy() {
    let alone = LaunchSwitches(environment: ["ARDIA_NATIVE_ICON_PICKER": "1", "ARDIA_NATIVE_SHELL": "1"], defaults: nil, distribution: false, skipStored: false)
    #expect(alone.requested(.nativeIconPicker, defaultOn: false))
    #expect(!alone.isOn(.nativeIconPicker, defaultOn: false))
    #expect(alone.unmetNeeds(.nativeIconPicker) == [.nativeSidebar])
    #expect(alone.refusals == ["ARDIA_NATIVE_ICON_PICKER is on but stays off: it needs ARDIA_NATIVE_SIDEBAR=1"])
    let met = LaunchSwitches(
      environment: ["ARDIA_NATIVE_ICON_PICKER": "1", "ARDIA_NATIVE_SHELL": "1", "ARDIA_NATIVE_SIDEBAR": "1"], defaults: nil, distribution: false, skipStored: false)
    #expect(met.isOn(.nativeIconPicker, defaultOn: false))
    #expect(met.refusals.isEmpty)

    let prompts = LaunchSwitches(environment: ["ARDIA_NATIVE_PANE_PROMPTS": "1", "ARDIA_NATIVE_SHELL": "1"], defaults: nil, distribution: false, skipStored: false)
    #expect(!prompts.isOn(.nativePanePrompts, defaultOn: false))
    #expect(prompts.refusals == ["ARDIA_NATIVE_PANE_PROMPTS is on but stays off: it needs ARDIA_NATIVE_PAGES_POOL=1"])

    let noShell = LaunchSwitches(
      environment: ["ARDIA_NATIVE_SHELL": "0", "ARDIA_SHELL_MAIN_TOP": "1", "ARDIA_SHELL_PANES": "1", "ARDIA_NATIVE_PAGES_POOL": "1", "ARDIA_NATIVE_TAB_PICKERS": "0"], defaults: nil, distribution: false, skipStored: false)
    #expect(!noShell.isOn(.shellMainTop, defaultOn: false))
    #expect(noShell.unmetNeeds(.shellMainTop) == [.shellPanes, .nativePagesPool])
    #expect(noShell.refusals.count == 3)
    #expect(LaunchSwitches(environment: [:], defaults: nil, distribution: false, skipStored: false).refusals.isEmpty)
    #expect(LaunchSwitches(environment: ["ARDIA_NATIVE_SHELL": "0", "ARDIA_SHELL_PANES": "0", "ARDIA_NATIVE_TAB_PICKERS": "0"], defaults: nil, distribution: false, skipStored: false).refusals.isEmpty)
  }

  @Test func theOneArgumentReadUsesTheSwitchsOwnDefault() {
    let empty = LaunchSwitches(environment: [:], defaults: nil, distribution: false, skipStored: false)
    for name in LaunchSwitch.allCases where !LaunchSwitch.developmentOnly.contains(name) {
      #expect(empty.isOn(name) == (LaunchSwitch.onByDefault.contains(name) && empty.unmetNeeds(name).isEmpty), "\(name.rawValue)")
    }
    let off = LaunchSwitches(environment: LaunchSwitch.onByDefault.reduce(into: [:]) { $0[$1.rawValue] = "0" }, defaults: nil, distribution: false, skipStored: false)
    #expect(LaunchSwitch.onByDefault.allSatisfy { !off.isOn($0) })
  }

  @Test func theWindowShellTabStripPickersAndMagnetAreOnByDefaultAndASavedZeroTurnsOneOff() {
    let plain = LaunchSwitches(environment: [:], defaults: scratchDefaults(), distribution: true, skipStored: false)
    for name: LaunchSwitch in [.nativeShell, .nativeTabPickers, .nativeTopStrip, .nativeDownloadMagnet] { #expect(plain.isOn(name), "\(name.rawValue)") }
    #expect(!plain.isOn(.shellPanes) && !plain.isOn(.nativeSidebar))
    let defaults = scratchDefaults()
    defaults.set("0", forKey: "ARDIA_NATIVE_SHELL")
    let off = LaunchSwitches(environment: [:], defaults: defaults, distribution: true, skipStored: false)
    #expect(!off.isOn(.nativeShell))
    #expect(!off.isOn(.nativeTabPickers))
    #expect(off.refusals == ["ARDIA_NATIVE_TAB_PICKERS is on but stays off: it needs ARDIA_NATIVE_SHELL=1"])
    #expect(off.isOn(.nativeTopStrip))
    let skipped = LaunchSwitches(environment: [:], defaults: defaults, distribution: true, skipStored: true)
    #expect(skipped.isOn(.nativeShell))
  }

  @Test func aSavedSwitchWhoseNeedsWereTurnedOffStaysOff() {
    let defaults = scratchDefaults()
    defaults.set("0", forKey: "ARDIA_NATIVE_SHELL")
    defaults.set("1", forKey: "ARDIA_SHELL_PANES")
    defaults.set("1", forKey: "ARDIA_NATIVE_TAB_PICKERS")
    let switches = LaunchSwitches(environment: [:], defaults: defaults, distribution: false, skipStored: false)
    #expect(!switches.isOn(.shellPanes, defaultOn: false))
    #expect(!switches.isOn(.nativeTabPickers, defaultOn: false))
    #expect(switches.refusals.count == 2)
    defaults.set("1", forKey: "ARDIA_NATIVE_SHELL")
    let withShell = LaunchSwitches(environment: [:], defaults: defaults, distribution: false, skipStored: false)
    #expect(withShell.isOn(.shellPanes, defaultOn: false))
    #expect(withShell.isOn(.nativeTabPickers, defaultOn: false))
    #expect(withShell.refusals.isEmpty)
  }

  @Test func twoLaunchesThatNeverFinishedTurnOffTheDefaultOnSwitchesAndTheSavedOnes() {
    for distribution in [false, true] {
      let defaults = scratchDefaults()
      defaults.set("1", forKey: "ARDIA_NATIVE_SIDEBAR")
      let launch = { LaunchSwitches.launching(environment: [:], defaults: defaults, distribution: distribution, optionHeld: { false }) }
      #expect(launch().countedLaunch)
      let second = launch()
      #expect(second.isOn(.nativeShell) && second.isOn(.nativeTopStrip) && second.isOn(.nativeSidebar))
      let third = launch()
      #expect(third.droppedAfterFailedLaunches)
      #expect(third.turnedOffByRecovery == [.nativeShell, .nativeSidebar, .nativeTopStrip])
      #expect(!third.isOn(.nativeShell) && !third.isOn(.nativeTopStrip) && !third.isOn(.nativeSidebar) && !third.isOn(.nativeTabPickers))
      #expect(defaults.string(forKey: "ARDIA_NATIVE_SHELL") == "0")
      #expect(defaults.string(forKey: "ARDIA_NATIVE_TOP_STRIP") == "0")
      #expect(defaults.object(forKey: "ARDIA_NATIVE_SIDEBAR") == nil)
      #expect(defaults.object(forKey: LaunchSwitches.failedLaunchesKey) == nil)
      let report = third.recoveryReport ?? ""
      #expect(report.hasPrefix("Solara didn't finish opening twice in a row"))
      #expect(report.contains("ARDIA_NATIVE_SHELL, ARDIA_NATIVE_SIDEBAR, ARDIA_NATIVE_TOP_STRIP"))
      #expect(report.contains("Settings › Advanced › Experimental") && report.contains("defaults delete"))
      let fourth = launch()
      #expect(!fourth.countedLaunch && !fourth.droppedAfterFailedLaunches && fourth.recoveryReport == nil)
      #expect(!fourth.isOn(.nativeShell))
      StoredLaunchSwitches(defaults: defaults, distribution: distribution).set(.nativeShell, nil)
      #expect(launch().countedLaunch)
      LaunchSwitches.launchSucceeded(defaults: defaults, isolated: false)
      #expect(launch().isOn(.nativeShell))
      #expect(launch().isOn(.nativeShell))
      #expect(launch().droppedAfterFailedLaunches)
    }
  }

  @Test func withNothingRecoveryCouldTurnOffALaunchIsNotCounted() {
    let defaults = scratchDefaults()
    for name in LaunchSwitch.recoverable { defaults.set("0", forKey: name.rawValue) }
    for _ in 0..<4 {
      let switches = LaunchSwitches.launching(environment: [:], defaults: defaults, distribution: false, optionHeld: { false })
      #expect(!switches.countedLaunch && !switches.droppedAfterFailedLaunches)
    }
    #expect(defaults.object(forKey: LaunchSwitches.failedLaunchesKey) == nil)
    #expect(LaunchSwitch.recoverable == [.nativeShell, .nativeTopStrip])
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

  @Test func holdingOptionTurnsOffTheDefaultOnSwitchesAndTheSavedOnesAndIsNotAFailedLaunch() {
    for distribution in [false, true] {
      let defaults = scratchDefaults()
      defaults.set("1", forKey: "ARDIA_NATIVE_SIDEBAR")
      defaults.set(1, forKey: LaunchSwitches.failedLaunchesKey)
      let held = LaunchSwitches.launching(environment: [:], defaults: defaults, distribution: distribution, optionHeld: { true })
      #expect(held.skippedStored && !held.countedLaunch)
      #expect(held.turnedOffByRecovery == [.nativeShell, .nativeSidebar, .nativeTopStrip])
      #expect(!held.isOn(.nativeShell) && !held.isOn(.nativeSidebar) && !held.isOn(.nativeTopStrip))
      #expect(held.isOn(.nativeDownloadMagnet), "a switch that can't be saved can't be turned off this way")
      #expect(defaults.string(forKey: "ARDIA_NATIVE_SHELL") == "0")
      #expect(defaults.string(forKey: "ARDIA_NATIVE_TOP_STRIP") == "0")
      #expect(defaults.object(forKey: "ARDIA_NATIVE_SIDEBAR") == nil)
      #expect(defaults.object(forKey: LaunchSwitches.failedLaunchesKey) == nil)
      #expect((held.recoveryReport ?? "").hasPrefix("Option was held while Solara opened"))
      let next = LaunchSwitches.launching(environment: [:], defaults: defaults, distribution: distribution, optionHeld: { false })
      #expect(!next.isOn(.nativeShell) && next.recoveryReport == nil && !next.countedLaunch)
      let again = LaunchSwitches.launching(environment: [:], defaults: defaults, distribution: distribution, optionHeld: { true })
      #expect(again.skippedStored && again.turnedOffByRecovery.isEmpty && again.recoveryReport == nil)
      let environment = LaunchSwitches.launching(environment: ["ARDIA_NATIVE_SHELL": "1"], defaults: defaults, distribution: distribution, optionHeld: { true })
      #expect(environment.isOn(.nativeShell))
    }
  }

  @Test func holdingOptionAsksFirstAndOpeningNormallyChangesNothing() {
    let defaults = scratchDefaults()
    defaults.set("1", forKey: "ARDIA_NATIVE_SIDEBAR")
    var asked: [[LaunchSwitch]] = []
    let declined = LaunchSwitches.launching(
      environment: [:], defaults: defaults, distribution: true, optionHeld: { true }, confirmRecovery: { asked.append($0); return false })
    #expect(asked == [[.nativeShell, .nativeSidebar, .nativeTopStrip]])
    #expect(!declined.skippedStored && declined.turnedOffByRecovery.isEmpty && declined.recoveryReport == nil)
    #expect(declined.isOn(.nativeShell) && declined.isOn(.nativeSidebar))
    #expect(declined.countedLaunch)
    #expect(defaults.object(forKey: "ARDIA_NATIVE_SHELL") == nil)
    #expect(defaults.string(forKey: "ARDIA_NATIVE_SIDEBAR") == "1")
    let accepted = LaunchSwitches.launching(
      environment: [:], defaults: defaults, distribution: true, optionHeld: { true }, confirmRecovery: { asked.append($0); return true })
    #expect(accepted.skippedStored && !accepted.isOn(.nativeShell))
    #expect(defaults.string(forKey: "ARDIA_NATIVE_SHELL") == "0")
    asked = []
    _ = LaunchSwitches.launching(environment: [:], defaults: defaults, distribution: true, optionHeld: { true }, confirmRecovery: { asked.append($0); return true })
    #expect(asked.isEmpty, "nothing left to turn off, so no question")
    _ = LaunchSwitches.launching(environment: ["ARDIA_DATA_DIR": "/tmp/x"], defaults: scratchDefaults(), distribution: false, optionHeld: { true }, confirmRecovery: { asked.append($0); return true })
    #expect(asked.isEmpty, "an isolated instance never asks")
    let question = LaunchSwitches.recoveryQuestion([.nativeShell, .nativeTopStrip])
    #expect(question.title == "Turn off the native window and the native tab strip?")
    #expect(question.message.contains("Settings › Advanced › Experimental"))
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
    #expect(LaunchSwitches.launching(environment: env, defaults: defaults, distribution: false, optionHeld: { false }).droppedAfterFailedLaunches)
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
        environment: [:], defaults: defaults, distribution: true, optionHeld: { answer != nil }, confirmRecovery: { _ in answer ?? false })
    }
    let first = LaunchSwitches.resolve(cell, ask: {
      lockFreeWhileAsking.append(cell.withLockIfAvailable { _ in true } ?? false)
      return true
    }, build: build)
    #expect(lockFreeWhileAsking == [true])
    #expect(answers == [true])
    #expect(first.skippedStored && !first.isOn(.nativeShell))
    #expect(defaults.string(forKey: "ARDIA_NATIVE_SHELL") == "0")
    let again = LaunchSwitches.resolve(cell, ask: {
      lockFreeWhileAsking.append(false)
      return false
    }, build: build)
    #expect(lockFreeWhileAsking == [true], "once resolved, nothing asks again")
    #expect(again.skippedStored && answers.count == 1)
  }
}
