import ArdiaCore
import ArdiaShell
import ExpoModulesCore

public class TabPoolModule: Module {
  public func definition() -> ModuleDefinition {
    Name("SolaraTabPool")
    Events("onPageEvent", "onPlaced")

    OnCreate {
      let sink = TabPoolSink(self)
      MainActor.assumeIsolated {
        TabPoolHost.shared.emit = { name, body in sink.module?.sendEvent(name, body) }
      }
    }

    Function("available") { () -> Bool in TabPoolHost.available }

    AsyncFunction("pageCall") { (tabId: String, method: String, args: [Any], promise: Promise) in
      nonisolated(unsafe) let reply = promise
      nonisolated(unsafe) let values = args
      MainActor.assumeIsolated {
        guard let page = TabPoolHost.shared.pageView(tabId) else {
          return reply.reject("ERR_NO_PAGE", "no pooled page for tab \(tabId)")
        }
        PageCalls.run(page, method, values, resolve: { reply.resolve($0) }, reject: { reply.reject($0, $1) })
      }
    }.runOnQueue(.main)

    AsyncFunction("claimFocusPage") { (generation: Int, tabId: String) -> Bool in
      MainActor.assumeIsolated {
        guard let page = TabPoolHost.shared.pageView(tabId) else { return false }
        FocusMoves.claim(generation, destination: page)
        return true
      }
    }.runOnQueue(.main)

    AsyncFunction("setPageProps") { (tabId: String, props: [String: Any]) in
      nonisolated(unsafe) let changed = props
      MainActor.assumeIsolated { TabPoolHost.shared.setPageProps(tabId, changed) }
    }.runOnQueue(.main)
  }
}

private final class TabPoolSink: @unchecked Sendable {
  weak var module: TabPoolModule?
  init(_ module: TabPoolModule) { self.module = module }
}
