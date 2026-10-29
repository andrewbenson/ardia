import Foundation
import SolaraModel
import Testing
@testable import SolaraUI

@MainActor
@Suite struct ExperimentsSectionTests {
  func scratchDefaults() -> UserDefaults {
    let name = "ExperimentsSectionTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defaults.removePersistentDomain(forName: name)
    return defaults
  }

  func model(environment: [String: String] = [:], defaults: UserDefaults, distribution: Bool = false) -> ExperimentsModel {
    let running = LaunchSwitches(environment: environment, defaults: defaults, distribution: distribution, skipStored: false)
    return ExperimentsModel(running: running, stored: StoredLaunchSwitches(running, defaults: defaults))
  }

  func row(_ model: ExperimentsModel, _ name: LaunchSwitch) -> ExperimentsModel.Row {
    model.rows.first { $0.name == name }!
  }

  @Test func theRowsAreTheEightInterfaceSwitchesWithTheirDependencies() {
    let model = model(defaults: scratchDefaults())
    #expect(model.rows.map(\.name) == [.nativeShell, .shellPanes, .nativeAutoHide, .nativeSidebar, .nativeTopStrip, .nativeMedia, .nativeToolTour, .nativeSidePanel])
    #expect(!model.rows.contains { $0.name == .nativePagesPool || $0.name == .shellMainTop })
    #expect(row(model, .shellPanes).needs == "Needs Native window.")
    #expect(row(model, .nativeAutoHide).needs == "Needs Native window.")
    #expect(row(model, .nativeSidebar).needs == nil)
  }

  @Test func aRowWhoseDependencyIsOffIsGreyedUntilItIsTurnedOn() {
    let defaults = scratchDefaults()
    let model = model(defaults: defaults)
    #expect(row(model, .nativeShell).on)
    #expect(row(model, .shellPanes).enabled)
    #expect(row(model, .nativeSidebar).enabled)
    #expect(!model.pendingRelaunch)
    model.set(.nativeShell, false)
    #expect(defaults.string(forKey: "ARDIA_NATIVE_SHELL") == "0")
    #expect(!row(model, .shellPanes).enabled)
    #expect(model.pendingRelaunch)
    model.set(.nativeShell, true)
    #expect(defaults.object(forKey: "ARDIA_NATIVE_SHELL") == nil)
    #expect(row(model, .shellPanes).enabled)
    #expect(!model.pendingRelaunch)
  }

  @Test func aSwitchSetWithoutItsDependencyShowsOffAndSaysWhy() {
    let environment = model(environment: ["ARDIA_NATIVE_SHELL": "0", "ARDIA_SHELL_PANES": "1"], defaults: scratchDefaults())
    #expect(!row(environment, .shellPanes).on)
    #expect(row(environment, .shellPanes).waiting == "Off until Native window is on.")
    #expect(row(environment, .nativeAutoHide).waiting == nil)
    let defaults = scratchDefaults()
    defaults.set("1", forKey: "ARDIA_NATIVE_AUTOHIDE")
    defaults.set("0", forKey: "ARDIA_NATIVE_SHELL")
    let saved = model(defaults: defaults)
    #expect(!row(saved, .nativeAutoHide).on)
    #expect(!row(saved, .nativeAutoHide).enabled)
    #expect(row(saved, .nativeAutoHide).waiting == "Off until Native window is on.")
    #expect(!saved.pendingRelaunch)
    saved.set(.nativeShell, true)
    #expect(row(saved, .nativeAutoHide).on)
    #expect(row(saved, .nativeAutoHide).waiting == nil)
    #expect(saved.pendingRelaunch)
  }

  @Test func turnAllOffClearsEverySavedSwitch() {
    let defaults = scratchDefaults()
    defaults.set("1", forKey: "ARDIA_NATIVE_SIDEBAR")
    defaults.set("1", forKey: "ARDIA_SHELL_MAIN_TOP")
    let model = model(defaults: defaults)
    model.turnAllOff()
    #expect(defaults.object(forKey: "ARDIA_NATIVE_SIDEBAR") == nil)
    #expect(defaults.object(forKey: "ARDIA_SHELL_MAIN_TOP") == nil)
    #expect(model.pendingRelaunch)
  }

  @Test func theSectionStaysHiddenUntilOptionOrASavedOrEnvironmentSwitch() {
    let empty = model(defaults: scratchDefaults())
    empty.reveal(optionHeld: false)
    #expect(!empty.revealed)
    empty.reveal(optionHeld: true)
    #expect(empty.revealed)
    let defaults = scratchDefaults()
    defaults.set("1", forKey: "ARDIA_NATIVE_MEDIA")
    let saved = model(defaults: defaults)
    saved.reveal(optionHeld: false)
    #expect(saved.revealed)
    let environment = model(environment: ["ARDIA_NATIVE_SIDEBAR": "1"], defaults: scratchDefaults())
    environment.reveal(optionHeld: false)
    #expect(environment.revealed)
  }

  @Test func anIsolatedInstanceShowsItsEnvironmentAndCannotSave() {
    let defaults = scratchDefaults()
    let model = model(environment: ["ARDIA_DATA_DIR": "/tmp/x", "ARDIA_NATIVE_SHELL": "1"], defaults: defaults)
    #expect(!model.stored.writable)
    #expect(model.recovery == nil)
    #expect(model.note.hasPrefix("This instance has its own data folder"))
    #expect(row(model, .nativeShell).on)
    #expect(row(model, .nativeShell).fromEnvironment)
    #expect(model.rows.allSatisfy { !$0.enabled })
    model.set(.nativeSidebar, true)
    #expect(defaults.object(forKey: "ARDIA_NATIVE_SIDEBAR") == nil)
  }

  @Test func theFooterGivesTheDefaultsDeleteLine() {
    let model = model(defaults: scratchDefaults())
    let recovery = model.recovery ?? ""
    #expect(recovery.contains("hold Option"))
    #expect(recovery.contains("defaults write "))
    #expect(recovery.contains("<NAME> 0"))
    #expect(recovery.contains("ARDIA_NATIVE_SHELL 0"))
  }

  @Test func theNoteSaysWhenSavedSwitchesWereDroppedAfterFailedLaunches() {
    let defaults = scratchDefaults()
    defaults.set("1", forKey: "ARDIA_NATIVE_SHELL")
    defaults.set(2, forKey: "SolaraLaunchSwitchFailedLaunches")
    let running = LaunchSwitches.launching(environment: [:], defaults: defaults, distribution: false, optionHeld: { false })
    let model = ExperimentsModel(running: running, stored: StoredLaunchSwitches(running, defaults: defaults))
    model.reveal(optionHeld: false)
    #expect(model.revealed)
    #expect(model.note == "Solara didn't finish opening twice in a row, so these were turned off: Native window, Native tab strip, Native side panel and Native tool tour.")
    #expect(model.recovery?.hasPrefix("To turn back on what Solara turned off, use its switch above, or in Terminal defaults delete ") == true)
    #expect(!row(model, .nativeShell).on && row(model, .nativeShell).enabled)
    model.set(.nativeShell, true)
    #expect(defaults.object(forKey: "ARDIA_NATIVE_SHELL") == nil)
  }

  @Test func theNoteNamesWhatHoldingOptionTurnedOff() {
    let defaults = scratchDefaults()
    defaults.set("1", forKey: "ARDIA_NATIVE_MEDIA")
    let running = LaunchSwitches.launching(environment: [:], defaults: defaults, distribution: true, optionHeld: { true })
    let model = ExperimentsModel(running: running, stored: StoredLaunchSwitches(running, defaults: defaults))
    model.reveal(optionHeld: false)
    #expect(model.revealed)
    #expect(model.note == "Option was held while Solara opened, so these were turned off: Native window, Native tab strip, Native media controls, Native side panel and Native tool tour.")
    #expect(!row(model, .nativeMedia).on && !row(model, .nativeTopStrip).on)
    let quiet = LaunchSwitches.launching(environment: [:], defaults: defaults, distribution: true, optionHeld: { true })
    #expect(ExperimentsModel(running: quiet, stored: StoredLaunchSwitches(quiet, defaults: defaults)).note == "Option was held while Solara opened, so nothing needed turning off.")
  }
}
