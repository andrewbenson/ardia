import AppKit
import ArdiaShell
import ExpoModulesCore
import SolaraUI

public class MediaModule: Module {
  public func definition() -> ModuleDefinition {
    Name("SolaraMedia")

    OnCreate {
      DispatchQueue.main.async {
        MainActor.assumeIsolated {
          NativeMedia.register()
          NativeLittleSolara.install()
          NativePaneOverlays.start()
          NativeDownloadsPanel.start()
        }
      }
    }

    Function("cliIndicatorShown") { () -> Bool? in NativeMedia.cliShown }

    #if DEBUG
      AsyncFunction("devSetCliIndicator") { (shown: Bool) in
        MainActor.assumeIsolated {
          let product = Bundle.main.productName
          CliPillIndicator.shared.set(shown: shown, product: product, command: product.lowercased())
        }
      }.runOnQueue(.main)
    #endif

    Function("littleActive") { (windowId: String) -> Bool in
      NativeMedia.enabled && NativeLittleSolara.active(windowId)
    }

    AsyncFunction("setLittleBar") { (windowId: String, json: String) in
      MainActor.assumeIsolated { NativeLittleSolara.host(windowId)?.setBar(json) }
    }.runOnQueue(.main)

    AsyncFunction("setLittleBackdrop") { (windowId: String, json: String) in
      MainActor.assumeIsolated { NativeLittleSolara.host(windowId)?.setBackdrop(json) }
    }.runOnQueue(.main)

    AsyncFunction("paneSwipe") { (windowId: String, tabId: String, json: String) in
      MainActor.assumeIsolated { NativePaneOverlays.swipe(windowId, tabId, json) }
    }.runOnQueue(.main)

    AsyncFunction("describePaneOverlays") { (windowId: String) -> String in
      MainActor.assumeIsolated { NativePaneOverlays.describe(windowId) }
    }.runOnQueue(.main)

    AsyncFunction("describeDownloadsPanel") { (windowId: String) -> String in
      MainActor.assumeIsolated { NativeDownloadsPanel.describe(windowId) }
    }.runOnQueue(.main)

    AsyncFunction("describeLittle") { (windowId: String) -> String in
      MainActor.assumeIsolated {
        guard let info = NativeLittleSolara.describe(windowId), let data = try? JSONSerialization.data(withJSONObject: info) else { return "null" }
        return String(data: data, encoding: .utf8) ?? "null"
      }
    }.runOnQueue(.main)

    Function("enabled") { () -> Bool in
      NativeMedia.enabled
    }

    AsyncFunction("probe") { (kind: String, windowId: String) -> String in
      MainActor.assumeIsolated { NativeMedia.probe(kind: kind, windowId: windowId) }
    }.runOnQueue(.main)
  }
}
