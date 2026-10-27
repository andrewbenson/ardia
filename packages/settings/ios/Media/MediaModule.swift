import AppKit
import ExpoModulesCore

public class MediaModule: Module {
  public func definition() -> ModuleDefinition {
    Name("SolaraMedia")

    OnCreate { DispatchQueue.main.async { MainActor.assumeIsolated { NativeMedia.register() } } }

    Function("enabled") { () -> Bool in
      NativeMedia.enabled
    }

    AsyncFunction("probe") { (kind: String, windowId: String) -> String in
      MainActor.assumeIsolated { NativeMedia.probe(kind: kind, windowId: windowId) }
    }.runOnQueue(.main)
  }
}
