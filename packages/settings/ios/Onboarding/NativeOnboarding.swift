import AppKit
import ArdiaShaders
import ArdiaShell
import Foundation
import SolaraModel
import SolaraStore
import SolaraUI
import SwiftUI

@MainActor
enum NativeOnboarding {
  static let kind = "onboarding"

  nonisolated static var enabled: Bool {
    ProcessInfo.processInfo.environment["ARDIA_NATIVE_ONBOARDING"] == "1" && NativeSettingsWindow.enabled
  }

  static func register() {
    guard enabled else { return }
    HostedViews.register(kind) { windowId in
      guard let settings = NativeSettingsHandle.model else { return nil }
      let session = OnboardingSession(windowId: windowId, settings: settings)
      return HostedContent(view: session.view, onUnmount: { session.end() })
    }
  }
}

@MainActor
final class OnboardingSession {
  let windowId: String
  let adapter: OnboardingAdapter
  let model: OnboardingModel
  private(set) var view: NSView = NSView()
  private var ended = false

  init(windowId: String, settings: SettingsModel) {
    self.windowId = windowId
    adapter = OnboardingAdapter(windowId: windowId, settings: settings)
    model = OnboardingModel(
      services: adapter, store: StoreSettingsSource(model: settings), diagnostics: DiagnosticsSharingAdapter(),
      appName: Bundle.main.productName, appIcon: NSApp.applicationIconImage)
    model.powerUpView = { spec in AnyView(OnboardingPowerUp(spec: spec)) }
    adapter.onWindowChange = { [weak model] in model?.refreshSettings() }
    let hosting = NSHostingView(rootView: OnboardingHostedRoot(model: model, windowId: windowId) { [weak self] in self?.dismissed() })
    hosting.safeAreaRegions = []
    view = hosting
    begin()
  }

  private func begin() {
    let saved = adapter.savedDocument
    let step = saved?.string("step").flatMap(OnboardingStep.init(rawValue:))
    let completed = saved?["completedAt"] is NSNumber
    if let step, step != .intro, !completed, saved?["startedAt"] is NSNumber {
      model.maybeStart()
    } else {
      model.start(windowId: windowId, step: step ?? .intro)
    }
  }

  private func dismissed() {
    guard !ended else { return }
    OnboardingAdapter.fire("onboarding.dismissed", windowId)
  }

  func end() {
    guard !ended else { return }
    ended = true
    if model.isActive { adapter.stopIntroMusic(fade: 0.2) }
    adapter.dispose()
  }
}

struct OnboardingHostedRoot: View {
  let model: OnboardingModel
  let windowId: String
  let onDismiss: () -> Void

  var body: some View {
    OnboardingOverlayView(model: model, windowId: windowId)
      .ignoresSafeArea()
      .onChange(of: model.isActive(in: windowId)) { was, now in
        if was && !now { onDismiss() }
      }
  }
}

struct OnboardingPowerUp: NSViewRepresentable {
  let spec: PowerUpSpec

  func makeNSView(context: Context) -> NSView {
    PowerUpViews.make(palette: spec.palette, speed: spec.speed, origin: spec.origin, cornerRadius: spec.cornerRadius, halo: spec.halo)
  }

  func updateNSView(_ view: NSView, context: Context) {}
}
