import Foundation
import Testing
@testable import SolaraModel

@Suite struct LaunchSwitchesTests {
  static let defaultOn: Set<LaunchSwitch> = [
    .nativeSettings, .nativeImport, .nativeOnboarding, .nativeNewTab, .nativeOmnibox, .nativeStatusBubble, .nativeStore, .nativePages,
  ]

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
    for name in Self.defaultOn { defaults.set("0", forKey: name.rawValue) }
    defaults.set("settingsAndDownloads", forKey: LaunchSwitches.scopeVariable)
    for distribution in [false, true] {
      let switches = LaunchSwitches(environment: [:], defaults: defaults, distribution: distribution, skipStored: false)
      for name in Self.defaultOn { #expect(switches.isOn(name, defaultOn: true), "\(name.rawValue)") }
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
      environment: ["ARDIA_SHELL_MAIN_TOP": "1", "ARDIA_SHELL_PANES": "1", "ARDIA_NATIVE_PAGES_POOL": "1"], defaults: nil, distribution: false, skipStored: false)
    #expect(!noShell.isOn(.shellMainTop, defaultOn: false))
    #expect(noShell.unmetNeeds(.shellMainTop) == [.shellPanes, .nativePagesPool])
    #expect(noShell.refusals.count == 3)
    #expect(LaunchSwitches(environment: [:], defaults: nil, distribution: false, skipStored: false).refusals.isEmpty)
    #expect(LaunchSwitches(environment: ["ARDIA_NATIVE_SHELL": "0", "ARDIA_SHELL_PANES": "0"], defaults: nil, distribution: false, skipStored: false).refusals.isEmpty)
  }

  @Test func aSavedSwitchWhoseNeedsWereTurnedOffStaysOff() {
    let defaults = scratchDefaults()
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

  @Test func savedSwitchesAreDroppedAfterTwoLaunchesThatNeverFinished() {
    let defaults = scratchDefaults()
    defaults.set("1", forKey: "ARDIA_NATIVE_SHELL")
    let launch = { LaunchSwitches.launching(environment: [:], defaults: defaults, distribution: false, optionHeld: { false }) }
    #expect(!LaunchSwitches.launching(environment: [:], defaults: scratchDefaults(), distribution: false, optionHeld: { false }).countedLaunch)
    #expect(launch().countedLaunch)
    #expect(launch().isOn(.nativeShell, defaultOn: false))
    let third = launch()
    #expect(!third.isOn(.nativeShell, defaultOn: false))
    #expect(third.droppedAfterFailedLaunches)
    #expect(defaults.object(forKey: "ARDIA_NATIVE_SHELL") == nil)
    defaults.set("1", forKey: "ARDIA_NATIVE_SHELL")
    #expect(launch().isOn(.nativeShell, defaultOn: false))
    LaunchSwitches.launchSucceeded(defaults: defaults, isolated: false)
    #expect(launch().isOn(.nativeShell, defaultOn: false))
    #expect(launch().isOn(.nativeShell, defaultOn: false))
    #expect(launch().droppedAfterFailedLaunches)
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

  @Test func holdingOptionDoesNotCountAsAFailedLaunch() {
    let defaults = scratchDefaults()
    defaults.set("1", forKey: "ARDIA_NATIVE_SHELL")
    for _ in 0..<3 {
      let switches = LaunchSwitches.launching(environment: [:], defaults: defaults, distribution: false, optionHeld: { true })
      #expect(switches.skippedStored)
    }
    #expect(defaults.string(forKey: "ARDIA_NATIVE_SHELL") == "1")
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
}
