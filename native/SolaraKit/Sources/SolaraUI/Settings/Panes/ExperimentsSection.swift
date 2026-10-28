import AppKit
import Observation
import SolaraModel
import SwiftUI

@MainActor
@Observable
public final class ExperimentsModel {
  @ObservationIgnored let running: LaunchSwitches
  @ObservationIgnored let stored: StoredLaunchSwitches
  var revision = 0
  var revealed = false

  public init(running: LaunchSwitches = .shared, stored: StoredLaunchSwitches? = nil) {
    self.running = running
    self.stored = stored ?? StoredLaunchSwitches(running)
  }

  static let titles: [LaunchSwitch: (title: String, detail: String)] = [
    .nativeShell: ("Native window", "The window's frame, page card and overlays, drawn by Solara's Swift interface."),
    .shellPanes: ("Native page overlays", "Each tab's overlays get their own place in the native window."),
    .nativeAutoHide: ("Native auto-hide", "Hiding the toolbar and sidebar, in the native window."),
    .nativeSidebar: ("Native sidebar", "The sidebar's tabs, pins, folders and hover cards."),
    .nativeTopStrip: ("Native tab strip", "The tab strip at the top of the window."),
    .nativeMedia: ("Native media controls", "The sidebar and mini players, the command line pill, and the share and cast pickers."),
  ]

  struct Row: Identifiable, Equatable {
    var id: LaunchSwitch { name }
    let name: LaunchSwitch
    let title: String
    let detail: String
    let needs: String?
    let on: Bool
    let enabled: Bool
    let fromEnvironment: Bool
  }

  func reveal(optionHeld: Bool) {
    revealed = revealed || optionHeld || stored.any || running.skippedStored || running.droppedAfterFailedLaunches
      || LaunchSwitch.experiments.contains(where: running.fromEnvironment)
  }

  func next(_ name: LaunchSwitch) -> Bool {
    _ = revision
    if running.fromEnvironment(name) { return running.isOn(name, defaultOn: false) }
    return stored.value(name) ?? false
  }

  var rows: [Row] {
    LaunchSwitch.experiments.map { name in
      let text = Self.titles[name] ?? (name.rawValue, "")
      let needs = name.needs.compactMap { Self.titles[$0]?.title }
      let fromEnvironment = running.fromEnvironment(name)
      return Row(
        name: name, title: text.title, detail: text.detail,
        needs: needs.isEmpty ? nil : "Needs \(needs.joined(separator: " and ")).",
        on: next(name),
        enabled: !fromEnvironment && stored.writable && name.needs.allSatisfy(next),
        fromEnvironment: fromEnvironment)
    }
  }

  var pendingRelaunch: Bool {
    LaunchSwitch.experiments.contains { next($0) != running.isOn($0, defaultOn: false) }
  }

  func set(_ name: LaunchSwitch, _ on: Bool) {
    stored.set(name, on ? true : nil)
    revision += 1
  }

  func turnAllOff() {
    stored.clear()
    revision += 1
  }

  var note: String {
    if !stored.writable { return "This instance has its own data folder, so only its environment sets these." }
    if running.droppedAfterFailedLaunches { return "Solara didn't finish opening twice in a row, so these were turned off." }
    if running.skippedStored { return "Option was held while Solara opened, so these were skipped this time." }
    return "These turn on parts of Solara that are still being built. Changes apply the next time Solara opens."
  }

  var recovery: String? {
    guard stored.writable else { return nil }
    let domain = Bundle.main.bundleIdentifier ?? "com.hill.solara"
    return "If Solara won't open with one on, hold Option while it opens to skip them, or turn one off in Terminal with defaults delete \(domain) <NAME>, for example defaults delete \(domain) \(LaunchSwitch.nativeShell.rawValue)."
  }
}

struct ExperimentsSection: View {
  let model: ExperimentsModel

  var body: some View {
    Section {
      ForEach(model.rows) { row in
        LabeledContent {
          Toggle("", isOn: Binding(get: { row.on }, set: { model.set(row.name, $0) }))
            .labelsHidden()
            .toggleStyle(.settingsSwitch)
            .disabled(!row.enabled)
        } label: {
          Text(row.title)
          Text([row.detail, row.needs, row.fromEnvironment ? "Set by the environment." : nil].compactMap { $0 }.joined(separator: " "))
            .foregroundStyle(.secondary)
        }
        .opacity(row.enabled || row.fromEnvironment ? 1 : 0.5)
      }
      if model.pendingRelaunch {
        Text("Relaunch Solara to apply.")
          .foregroundStyle(.secondary)
      }
    } header: {
      SettingsSectionHeader("Experimental", description: model.note) {
        if model.stored.writable && (model.stored.any || model.running.skippedStored) {
          Button("Turn All Off") { model.turnAllOff() }
        }
      }
    } footer: {
      if let recovery = model.recovery {
        Text(recovery)
          .font(.callout)
          .foregroundStyle(.secondary)
          .textSelection(.enabled)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
  }
}
