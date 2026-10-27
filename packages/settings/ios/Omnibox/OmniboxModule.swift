import AppKit
import ExpoModulesCore
import Foundation
import SolaraStore
import SolaraUI

public class OmniboxModule: Module {
  public func definition() -> ModuleDefinition {
    Name("SolaraOmniboxBar")

    Function("available") { () -> Bool in
      ProcessInfo.processInfo.environment["ARDIA_NATIVE_OMNIBOX"] == "1" && NativeSettingsHandle.active
    }

    View(NativeOmniboxView.self) {
      Events(NativeOmniboxView.events)

      Prop("windowId") { (view: NativeOmniboxView, v: String) in MainActor.assumeIsolated { view.windowId = v } }
      Prop("tabId") { (view: NativeOmniboxView, v: String) in MainActor.assumeIsolated { view.tabId = v } }
      Prop("profileId") { (view: NativeOmniboxView, v: String) in MainActor.assumeIsolated { view.profileId = v } }
      Prop("variant") { (view: NativeOmniboxView, v: String) in MainActor.assumeIsolated { view.variant = BarVariant(rawValue: v) ?? .panel } }
      Prop("opensTab") { (view: NativeOmniboxView, v: Bool?) in MainActor.assumeIsolated { view.opensTab = v ?? false } }
      Prop("initialText") { (view: NativeOmniboxView, v: String?) in MainActor.assumeIsolated { view.initialText = v ?? "" } }
      Prop("floating") { (view: NativeOmniboxView, v: Bool?) in MainActor.assumeIsolated { view.bar.floating = v ?? false } }
      Prop("incognito") { (view: NativeOmniboxView, v: Bool?) in MainActor.assumeIsolated { view.bar.incognito = v ?? false } }
      Prop("currentUrl") { (view: NativeOmniboxView, v: String?) in MainActor.assumeIsolated { view.bar.currentUrl = v ?? "" } }
      Prop("openTabs") { (view: NativeOmniboxView, v: String?) in MainActor.assumeIsolated { view.setOpenTabs(v ?? "[]") } }
      Prop("dark") { (view: NativeOmniboxView, v: Bool?) in MainActor.assumeIsolated { view.dark = v ?? false } }
      Prop("theme") { (view: NativeOmniboxView, v: [String: String]?) in MainActor.assumeIsolated { view.themeTokens = v ?? [:] } }
      Prop("offline") { (view: NativeOmniboxView, v: Bool?) in MainActor.assumeIsolated { view.bar.fetcher = v == true ? nil : NewTabNetwork.fetcher } }
      Prop("driven") { (view: NativeOmniboxView, v: Bool?) in MainActor.assumeIsolated { view.driven = v ?? false } }

      OnViewDidUpdateProps { (view: NativeOmniboxView) in MainActor.assumeIsolated { view.propsDidUpdate() } }

      AsyncFunction("focus") { (view: NativeOmniboxView) in MainActor.assumeIsolated { view.bar.focusBar() } }.runOnQueue(.main)

      AsyncFunction("applyMenu") { (view: NativeOmniboxView, choice: String) in
        MainActor.assumeIsolated { if let c = HeroMenuChoice(rawValue: choice) { view.bar.model?.apply(c) } }
      }.runOnQueue(.main)

      AsyncFunction("type") { (view: NativeOmniboxView, text: String) in
        MainActor.assumeIsolated { view.bar.model?.driverType(text) }
      }.runOnQueue(.main)

      AsyncFunction("clear") { (view: NativeOmniboxView) in MainActor.assumeIsolated { view.bar.model?.reset() } }.runOnQueue(.main)

      AsyncFunction("key") { (view: NativeOmniboxView, key: String, mods: [String: Bool]?) in
        MainActor.assumeIsolated { _ = view.bar.model?.driverKey(key, mods ?? [:]) }
      }.runOnQueue(.main)

      AsyncFunction("select") { (view: NativeOmniboxView, start: Int, end: Int) in
        MainActor.assumeIsolated { view.bar.model?.selectionChanged(TextSelection(start: start, end: end)) }
      }.runOnQueue(.main)

      AsyncFunction("submit") { (view: NativeOmniboxView) in MainActor.assumeIsolated { view.bar.model?.submit() } }.runOnQueue(.main)

      AsyncFunction("state") { (view: NativeOmniboxView) -> String in MainActor.assumeIsolated { view.driverStateJSON() } }.runOnQueue(.main)

      AsyncFunction("measure") { (view: NativeOmniboxView) -> [String: Double] in MainActor.assumeIsolated { view.measure() } }.runOnQueue(.main)
    }
  }
}
