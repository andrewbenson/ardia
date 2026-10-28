import ExpoModulesCore
internal import SolaraBridgeCore
internal import SolaraModel

public class StoreModule: Module {
  private var subscription: Int?

  public func definition() -> ModuleDefinition {
    Name("ArdiaStore")

    Events("onStoreCommit")

    Function("status") { () -> [String: Any] in
      let syncRedesign = LaunchSwitch(rawValue: "ARDIA_SYNC_REDESIGN").map { LaunchSwitches.shared.isOn($0, defaultOn: false) } ?? false
      if NativeStore.shared != nil { return ["active": true, "scope": NativeStore.ownsWorkspace ? "everything" : "settingsAndDownloads", "syncRedesign": syncRedesign] }
      var status: [String: Any] = [
        "active": false, "reason": NativeStore.unavailableReason ?? "not launched", "handedOff": NativeStore.handedOff, "syncRedesign": syncRedesign,
      ]
      if let refusedSession = NativeStore.refusedSession { status["refusedSession"] = refusedSession }
      return status
    }

    Function("snapshot") { () -> String? in
      NativeStore.shared?.bridge.snapshotJSON()
    }

    Function("dispatch") { (commandJSON: String, sinceRev: Int) -> String? in
      NativeStore.shared?.bridge.dispatch(commandJSON, sinceRev: sinceRev)
    }

    Function("catchUp") { (sinceRev: Int) -> String? in
      guard let bridge = NativeStore.shared?.bridge else { return nil }
      return JSONValue.object(bridge.catchUp(sinceRev: sinceRev)).text()
    }

    Function("useSyncOrigins") { (on: Bool) -> Bool in
      guard let store = NativeStore.shared else { return false }
      store.bridge.store.useSyncOrigins(on)
      return true
    }

    Function("syncAnchor") { () -> String? in
      NativeStore.shared?.writer.syncAnchor
    }

    Function("setSyncAnchor") { (anchor: String) -> Bool in
      guard let store = NativeStore.shared else { return false }
      store.writer.setSyncAnchor(anchor)
      return true
    }

    Function("freeze") { () -> Bool in
      NativeStore.shared?.freeze()
      return NativeStore.shared != nil
    }

    Function("flush") { (timeout: Double) -> Bool in
      NativeStore.shared?.flush(timeout: timeout) ?? false
    }

    OnStartObserving {
      guard self.subscription == nil, let bridge = NativeStore.shared?.bridge else { return }
      let sink = EventSink(module: self)
      self.subscription = bridge.observeForeignCommits { event in
        sink.module?.sendEvent("onStoreCommit", ["event": event])
      }
    }

    OnStopObserving {
      if let id = self.subscription { NativeStore.shared?.bridge.store.unsubscribe(id) }
      self.subscription = nil
    }
  }
}

final class EventSink: @unchecked Sendable {
  weak var module: StoreModule?

  init(module: StoreModule) {
    self.module = module
  }
}
