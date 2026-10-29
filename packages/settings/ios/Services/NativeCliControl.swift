import AppKit
import ArdiaCore
import ArdiaShell
import Foundation
import Observation
import SolaraModel
import SolaraStore
import SolaraUI

@MainActor
@Observable
final class NativeCliControl {
  static let shared = NativeCliControl()
  static let document = "ardia-cli.json"
  static let upgradeDelay: TimeInterval = 8
  static let indicatorHold: TimeInterval = 3

  nonisolated static var enabled: Bool { LaunchSwitches.shared.isOn(.nativeServices, defaultOn: false) }
  nonisolated static let active: Bool = enabled && NativeSettingsHandle.active

  private(set) var server: CliControlServer?
  private(set) var installing: String?
  private(set) var step: String?
  private(set) var installedVersion: String?
  private(set) var binPath: String?
  private(set) var error: String?
  private(set) var indicatorShown = false {
    didSet { showPill() }
  }

  var topic: [String: Any] {
    var out: [String: Any] = ["installing": installing != nil]
    if let server {
      var entry: [String: Any] = ["state": server.state]
      if let reason = server.reason { entry["reason"] = reason }
      if let connections = server.connections { entry["connections"] = connections }
      out["server"] = entry
    }
    if let step { out["step"] = step }
    if let installedVersion { out["installedVersion"] = installedVersion }
    if let binPath { out["binPath"] = binPath }
    if let error { out["error"] = error }
    return out
  }

  @ObservationIgnored private var sync = CliControlSync()
  @ObservationIgnored private var model: SettingsModel?
  @ObservationIgnored private var started = false
  @ObservationIgnored private var indicatorHide: DispatchWorkItem?
  @ObservationIgnored private var running: [([String: Any]) -> Void] = []

  private init() {
    let saved = Self.readSaved()
    installedVersion = CliTool.installedVersion()
    binPath = saved["binPath"] as? String
    error = saved["error"] as? String
  }

  func startWhenReady(tries: Int = 40) {
    guard Self.active, !started else { return }
    if let model = NativeSettingsHandle.model { return start(model: model) }
    guard tries > 0 else { return NSLog("[cli] the native store never opened, so CLI control stays off") }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { NativeCliControl.shared.startWhenReady(tries: tries - 1) }
  }

  func start(model: SettingsModel) {
    guard Self.active, !started else { return }
    started = true
    self.model = model
    CliPillIndicator.shared.onStop = { NativeCliControl.shared.stop() }
    showPill()
    ArdiaCoreEngineBridge.observe("cliControl") { @Sendable payload in
      let status = CliControlServer(payload)
      Task { @MainActor in NativeCliControl.shared.heard(status) }
    }
    settingChanged()
    DispatchQueue.main.asyncAfter(deadline: .now() + Self.upgradeDelay) { [weak self] in self?.upgradeIfBehind() }
  }

  private var settingOn: Bool { model?.value("cliControl")?.bool ?? false }

  private func settingChanged() {
    withObservationTracking {
      _ = model?.settings
    } onChange: {
      Task { @MainActor in NativeCliControl.shared.settingChanged() }
    }
    guard let call = sync.settingChanged(settingOn) else { return }
    let args: [String: Any]? = switch call.call {
    case .status: nil
    case .set(let on): ["on": on]
    }
    ArdiaCoreServices.call("ac_cli_control", profile: "", args: args) { @Sendable result in
      let status = CliControlServer(result)
      Task { @MainActor in NativeCliControl.shared.settled(call.request, status) }
    }
  }

  private func settled(_ request: Int, _ status: CliControlServer) {
    if sync.settled(request, status, settingOn: settingOn) { stop() }
    adoptServer()
  }

  private func heard(_ status: CliControlServer) {
    if sync.event(status, settingOn: settingOn) { stop() }
    adoptServer()
  }

  private func adoptServer() {
    if server != sync.server { server = sync.server }
    updateIndicator()
  }

  func stop() {
    model?.update(["cliControl": .bool(false)])
  }

  private func showPill() {
    CliPillIndicator.shared.set(shown: indicatorShown, product: CliTool.product, command: CliTool.command)
  }

  private func updateIndicator() {
    let on = server?.state == "on"
    let connected = on && (server?.connections ?? 0) > 0
    if connected || !on {
      indicatorHide?.cancel()
      indicatorHide = nil
      if indicatorShown != connected { indicatorShown = connected }
      return
    }
    guard indicatorShown, indicatorHide == nil else { return }
    let hide = DispatchWorkItem { [weak self] in
      self?.indicatorHide = nil
      self?.indicatorShown = false
    }
    indicatorHide = hide
    DispatchQueue.main.asyncAfter(deadline: .now() + Self.indicatorHold, execute: hide)
  }

  func install(reason: String, done: (([String: Any]) -> Void)? = nil) {
    if let done { running.append(done) }
    guard installing == nil else { return }
    installing = reason
    step = nil
    CliTool.install(
      onLine: { @Sendable line in
        guard line.hasPrefix("step "), let step = line.dropFirst(5).split(separator: " ").first else { return }
        Task { @MainActor in NativeCliControl.shared.step = String(step) }
      },
      done: { @Sendable result in
        nonisolated(unsafe) let result = result
        Task { @MainActor in NativeCliControl.shared.installed(result) }
      })
  }

  private func installed(_ result: [String: Any]) {
    let version = CliTool.installedVersion()
    if result["ok"] as? Bool == true {
      let path = result["binPath"] as? String
      Self.save(["binPath": path ?? NSNull(), "version": (result["version"] as? String) ?? version ?? NSNull(), "error": NSNull()])
      binPath = path
      error = nil
    } else {
      let message = (result["error"] as? String) ?? "The installer stopped."
      Self.save(["error": message])
      error = message
    }
    installing = nil
    step = nil
    installedVersion = version
    let waiting = running
    running = []
    for done in waiting { done(result) }
  }

  private func upgradeIfBehind() {
    let installed = CliTool.installedVersion()
    installedVersion = installed
    let app = CliTool.appVersion
    guard let installed, !app.isEmpty, installed != app else { return }
    install(reason: "upgrade")
  }

  private static func readSaved() -> [String: Any] {
    guard let json = DocumentStore.read(document), let data = json.data(using: .utf8),
      let saved = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return [:] }
    return saved
  }

  private static func save(_ patch: [String: Any]) {
    var saved = readSaved()
    for (key, value) in patch { saved[key] = value }
    saved["at"] = (Date().timeIntervalSince1970 * 1000).rounded()
    guard let data = try? JSONSerialization.data(withJSONObject: saved), let json = String(data: data, encoding: .utf8) else { return }
    do { try DocumentStore.write(document, json) } catch { NSLog("[cli] couldn't save the install status: %@", String(describing: error)) }
  }
}
