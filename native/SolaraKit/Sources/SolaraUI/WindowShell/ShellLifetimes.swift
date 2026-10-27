import Foundation

@MainActor
public final class ShellLifetimes<Host: AnyObject> {
  private var hosts: [String: Host] = [:]
  private var known: Set<String> = []
  private let stop: (Host) -> Void
  public var onIds: ((Set<String>) -> Void)?

  public init(stop: @escaping (Host) -> Void) {
    self.stop = stop
  }

  public var ids: Set<String> { Set(hosts.keys) }

  public func host(_ id: String) -> Host? { hosts[id] }

  public func adopt(_ id: String, _ host: Host) {
    let previous = hosts[id]
    hosts[id] = host
    if let previous, previous !== host { stop(previous) }
    onIds?(ids)
  }

  public func end(_ id: String, ifHost host: Host? = nil) {
    guard let current = hosts[id], host == nil || current === host else { return }
    hosts[id] = nil
    known.remove(id)
    stop(current)
    onIds?(ids)
  }

  public func prune(keeping live: Set<String>) {
    known.formUnion(live.filter { hosts[$0] != nil })
    let gone = known.filter { !live.contains($0) }
    known.subtract(gone)
    let ended = gone.compactMap { hosts.removeValue(forKey: $0) }
    guard !ended.isEmpty else { return }
    for host in ended { stop(host) }
    onIds?(ids)
  }
}
