import SwiftUI

@MainActor
public protocol DiagnosticsSharingServices: AnyObject {
  var available: Bool { get }
  var sharing: Bool { get }
  func setSharing(_ on: Bool, source: String)
  var telemetryHost: String { get }
  var updateHost: String { get }
  var switchFile: String { get }
}

struct DiagnosticsCopy {
  let appName: String
  let telemetryHost: String
  let updateHost: String
  let switchFile: String

  init(appName: String, telemetryHost: String, updateHost: String, switchFile: String) {
    self.appName = appName
    self.telemetryHost = telemetryHost
    self.updateHost = updateHost
    self.switchFile = switchFile
  }

  @MainActor
  init(appName: String, services: DiagnosticsSharingServices?) {
    self.init(
      appName: appName,
      telemetryHost: services?.telemetryHost ?? "",
      updateHost: services?.updateHost ?? "",
      switchFile: services?.switchFile ?? ""
    )
  }

  let toggle = "Share anonymous crash reports and usage stats"
  let summary = "Crashes, errors, rough feature counts and speed. Never the sites you visit, anything you type or search, or what's in your tabs."
  let whatsSent = "What's Sent"

  var footnote: String {
    "Sent to \(telemetryHost) with a random ID made on this Mac, and kept on our own servers. No third parties. Turning this off stops it at once and deletes anything waiting to be sent. This setting doesn't sync."
  }

  let dailyCount = "One anonymous “opened today” count a day: app version, update channel, macOS version, chip, and whether it's this copy's first day, week or month. No persistent ID."

  var dailyCountShort: String {
    "Either way, \(appName) sends one anonymous “opened today” count a day, with its version and macOS version and no persistent ID."
  }

  var updateChecks: String {
    "\(updateHost) counts update checks by version and day, and whether it's this copy's first. Nothing else."
  }

  var switchFileNote: String {
    "While update checks are on, each launch also reads \(switchFile): one small file, the same for everyone, that lets us turn off a speed-up that misbehaves. It sends no ID, no cookies and nothing about you."
  }

  var sheetSubtitle: String {
    "Only while “\(toggle)” is on, except what’s under “Even with sharing off”."
  }

  var groups: [(title: String, items: [String])] {
    [
      ("With everything", [
        "A random install ID, made on this Mac (a new one each time sharing is turned back on)",
        "App version and build, macOS version, chip (arm64 or x86_64), engine version",
        "Whether it's a test build",
      ]),
      ("Crashes and errors", [
        "The error's type and message, with web addresses, paths, file names, quoted text and long numbers taken out",
        "Function names, script file names and line numbers from the stack trace",
        "After a crash: the exception type and name (never its message), and the function names where it was thrown and on the crashing thread, from this app's crash report",
        "Warning and error log lines, cleaned the same way",
      ]),
      ("Usage", [
        "Launches, updates, and whether the last session ended cleanly",
        "How many tabs and windows you open (a count, not which)",
        "Opening split view, switching profiles and opening the command bar",
        "The kind of command bar row you pick: history, bookmark, tab, address, search, calculator or action",
        "Installing an extension, turning sync on or off, translating a page, and which Settings sections you open",
      ]),
      ("Speed", [
        "Time to the first window, profile switch time, and command bar speed (a sample of keystrokes)",
        "How long launches, new tabs, tab switches and page loads take, step by step: times and counts only, summed up once an hour",
        "At launch, in rough ranges: how many tabs and windows came back, how much history there is, and whether it's the first launch since the Mac started",
        "Memory use and the number of tabs, once an hour",
      ]),
      ("Even with sharing off", [dailyCount, updateChecks, switchFileNote]),
      ("Never", [
        "Web addresses, site names or page titles",
        "Anything you type or search for",
        "History, bookmarks, passwords or what's in your tabs",
        "Profile, extension or file names",
        "Screen recordings",
      ]),
    ]
  }
}

struct ShareDiagnosticsSection: View {
  @Environment(\.settingsContext) private var context
  let model: PrivacyPaneModel

  var body: some View {
    if model.diagnosticsAvailable {
      let copy = DiagnosticsCopy(appName: context?.appName ?? "", services: model.diagnostics)
      SettingsSection("Crash reports and usage", description: copy.dailyCountShort) {
        SettingRow("privacy.shareDiagnostics", description: copy.summary) {
          Toggle("", isOn: Binding(get: { model.sharing }, set: { model.setSharing($0) }))
            .labelsHidden()
            .toggleStyle(.switch)
        }
        Button { model.sheet = .whatsSent } label: {
          SettingRow("privacy.whatsSent") {
            Image(systemName: "chevron.right")
              .font(.system(size: 11, weight: .semibold))
              .foregroundStyle(.tertiary)
          }
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
      }
    }
  }
}

struct WhatsSentSheet: View {
  let copy: DiagnosticsCopy
  let done: () -> Void

  var body: some View {
    VStack(spacing: 0) {
      PrivacySheetHeader(title: copy.whatsSent, subtitle: copy.sheetSubtitle)
      Form {
        ForEach(copy.groups, id: \.title) { group in
          Section(group.title) {
            ForEach(group.items, id: \.self) { item in
              Text(item)
                .fixedSize(horizontal: false, vertical: true)
            }
          }
        }
      }
      .formStyle(.grouped)
      .frame(height: 420)
      PrivacySheetFooter(note: copy.footnote, done: done)
    }
    .frame(width: 500)
  }
}
