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

  @Test func environmentValuesReadAsTheOldEqualsOneAndNotZeroChecksDid() {
    for name in LaunchSwitch.allCases {
      let on = Self.defaultOn.contains(name)
      for (text, expected) in [("", on), ("1", true), ("0", false), ("true", on), ("off", on)] {
        let switches = LaunchSwitches(environment: [name.rawValue: text], defaults: nil, distribution: false, skipStored: false)
        let old = on ? text != "0" : text == "1"
        #expect(switches.isOn(name, defaultOn: on) == expected, "\(name.rawValue)=\(text)")
        #expect(expected == old, "\(name.rawValue)=\(text)")
      }
      #expect(LaunchSwitches(environment: [:], defaults: nil, distribution: false, skipStored: false).isOn(name, defaultOn: on) == on)
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
}

