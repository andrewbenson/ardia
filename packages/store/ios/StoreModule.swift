import ExpoModulesCore
internal import SolaraBridgeCore
internal import SolaraModel

public class StoreModule: Module {
  private var subscription: Int?

  public func definition() -> ModuleDefinition {
    Name("ArdiaStore")

    Events("onStoreCommit")

    Function("status") { () -> [String: Any] in
      if NativeStore.shared != nil { return ["active": true, "scope": NativeStore.ownsWorkspace ? "everything" : "settingsAndDownloads"] }
      return ["active": false, "reason": NativeStore.unavailableReason ?? "not launched", "handedOff": NativeStore.handedOff]
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
