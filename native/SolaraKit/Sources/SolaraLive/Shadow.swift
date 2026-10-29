import Foundation

public actor LiveShadow {
  private let effects: LiveEffects
  private var engine: LiveEngine

  public init(effects: LiveEffects) {
    self.effects = effects
    engine = LiveEngine(effects: effects)
  }

  public func reload() {
    engine = LiveEngine(effects: effects)
  }

  public func snapshot() async -> LiveSnapshot {
    while true {
      let current = engine
      let state = await current.snapshot
      if current === engine { return state }
    }
  }
}
