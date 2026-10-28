import ExpoModulesCore
import Foundation

public class SettingsModule: Module {
  public func definition() -> ModuleDefinition {
    Name("SolaraSettings")

    Events("onSettingsCall")

    OnCreate {
      DispatchQueue.main.async { MainActor.assumeIsolated { NativeSettingsWindow.install() } }
    }

    Function("available") { () -> Bool in
      NativeSettingsWindow.enabled
    }

    Function("servicesActive") { () -> Bool in
      NativeCliControl.active
    }

    AsyncFunction("navigate") { (pane: String?, profileId: String?, detail: String?) in
      MainActor.assumeIsolated { NativeSettingsWindow.navigate(pane: pane, profileId: profileId, detail: detail) }
    }.runOnQueue(.main)

    AsyncFunction("devImport") { (action: String, argument: String?, promise: Promise) in
      nonisolated(unsafe) let reply = promise
      MainActor.assumeIsolated {
        Task { @MainActor in
          let result = await NativeImportWindow.drive(action, argument)
          nonisolated(unsafe) let sendable = result
          reply.resolve(sendable)
        }
      }
    }.runOnQueue(.main)

    AsyncFunction("devOnboarding") { (action: String, argument: String?) -> String in
      MainActor.assumeIsolated { NativeOnboarding.drive(action, argument) }
    }.runOnQueue(.main)

    AsyncFunction("devSettings") { (action: String, argument: String?) -> String in
      MainActor.assumeIsolated { SettingsDev.drive(action, argument) }
    }.runOnQueue(.main)

    AsyncFunction("devSettingsSwitch") { (pane: String, promise: Promise) in
      nonisolated(unsafe) let reply = promise
      MainActor.assumeIsolated { SettingsDev.switchPane(pane) { reply.resolve($0) } }
    }.runOnQueue(.main)

    AsyncFunction("devTimings") { () -> String in
      MainActor.assumeIsolated { SettingsTimings.takeJSON() }
    }.runOnQueue(.main)

    AsyncFunction("focusSearch") {
      MainActor.assumeIsolated { NativeSettingsWindow.focusSearch() }
    }.runOnQueue(.main)

    AsyncFunction("reply") { (id: Int, resultJSON: String?, error: String?) in
      MainActor.assumeIsolated { SettingsJS.shared.reply(id, resultJSON: resultJSON, error: error) }
    }.runOnQueue(.main)

    AsyncFunction("publish") { (topic: String, json: String) in
      MainActor.assumeIsolated { SettingsJS.shared.publish(topic, json: json) }
    }.runOnQueue(.main)

    OnStartObserving {
      let sink = SettingsEventSink(module: self)
      DispatchQueue.main.async {
        MainActor.assumeIsolated {
          SettingsJS.shared.send = { id, name, args in
            sink.module?.sendEvent("onSettingsCall", ["id": id, "name": name, "args": args])
          }
        }
      }
    }

    OnStopObserving {
      DispatchQueue.main.async {
        MainActor.assumeIsolated {
          SettingsJS.shared.send = nil
          SettingsJS.shared.failAll("JS stopped listening for Settings calls")
        }
      }
    }
  }
}

final class SettingsEventSink: @unchecked Sendable {
  weak var module: SettingsModule?

  init(module: SettingsModule) {
    self.module = module
  }
}
