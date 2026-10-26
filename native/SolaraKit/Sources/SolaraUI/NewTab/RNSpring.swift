import Darwin
import Foundation

public struct SpringParams: Sendable, Equatable {
  public var stiffness: Double
  public var damping: Double
  public var mass: Double

  public init(stiffness: Double, damping: Double, mass: Double = 1) {
    self.stiffness = stiffness
    self.damping = damping
    self.mass = mass
  }

  public init(response: Double, dampingRatio: Double) {
    self.init(stiffness: pow(2 * Double.pi / response, 2), damping: 4 * Double.pi * dampingRatio / response)
  }
}

public struct RNSpring: Sendable, Equatable {
  public static let maxDeltaTime: Double = 0.064
  public static let restThreshold: Double = 0.001

  public let params: SpringParams
  public let from: Double
  public let to: Double
  public let initialVelocity: Double
  public private(set) var value: Double
  public private(set) var velocity: Double
  public private(set) var finished = false
  private var t: Double = 0
  private var lastTime: Double?

  public init(_ params: SpringParams, from: Double, to: Double = 0, initialVelocity: Double = 0) {
    self.params = params
    self.from = from
    self.to = to
    self.initialVelocity = initialVelocity
    value = from
    velocity = initialVelocity
  }

  public mutating func step(at time: Double) -> Double {
    if finished { return value }
    if let lastTime {
      t += min(RNSpring.maxDeltaTime, time - lastTime)
    } else {
      t = 0
    }
    lastTime = time
    let (position, speed) = RNSpring.solve(params, from: from, to: to, initialVelocity: initialVelocity, t: t)
    value = position
    velocity = speed
    let still = abs(speed) <= RNSpring.restThreshold
    let settled = params.stiffness == 0 || abs(to - position) <= RNSpring.restThreshold
    if still && settled {
      if params.stiffness != 0 { value = to }
      finished = true
    }
    return value
  }

  public static func solve(_ p: SpringParams, from: Double, to: Double, initialVelocity: Double, t: Double) -> (Double, Double) {
    let c = p.damping
    let m = p.mass
    let k = p.stiffness
    let v0 = -initialVelocity
    let zeta = c / (2 * Double(sqrtf(Float(k * m))))
    let omega0 = Double(sqrtf(Float(k / m)))
    let omega1 = omega0 * Double(sqrtf(Float(1.0 - zeta * zeta)))
    let x0 = to - from
    if zeta < 1 {
      let envelope = Double(expf(Float(-zeta * omega0 * t)))
      let s = Double(sinf(Float(omega1 * t)))
      let co = Double(cosf(Float(omega1 * t)))
      let position = to - envelope * ((v0 + zeta * omega0 * x0) / omega1 * s + x0 * co)
      let speed = zeta * omega0 * envelope * (s * (v0 + zeta * omega0 * x0) / omega1 + x0 * co) - envelope * (co * (v0 + zeta * omega0 * x0) - omega1 * x0 * s)
      return (position, speed)
    }
    let envelope = Double(expf(Float(-omega0 * t)))
    let position = to - envelope * (x0 + (v0 + omega0 * x0) * t)
    let speed = envelope * (v0 * (t * omega0 - 1) + t * x0 * (omega0 * omega0))
    return (position, speed)
  }
}

public struct MarkLayer: Sendable, Equatable {
  public enum Name: String, Sendable, CaseIterable {
    case sun, back, front
  }

  public let name: Name
  public let hidden: Double
  public let delay: Double
  public let spring: SpringParams
}

public enum MarkIntro {
  public static let sunDelay: Double = 0.25
  public static let sunDrift: Double = 6
  public static let sunDriftSpring = SpringParams(response: 0.6, dampingRatio: 1)
  public static let layers: [MarkLayer] = [
    MarkLayer(name: .sun, hidden: 56, delay: sunDelay, spring: SpringParams(response: 0.56, dampingRatio: 0.9)),
    MarkLayer(name: .back, hidden: 40.5, delay: 0.17, spring: SpringParams(response: 0.46, dampingRatio: 0.84)),
    MarkLayer(name: .front, hidden: 34, delay: 0.08, spring: SpringParams(response: 0.42, dampingRatio: 0.76)),
  ]
}

public struct MarkOffsets: Sendable, Equatable {
  public var sunX: Double
  public var y: [MarkLayer.Name: Double]

  public static let rest = MarkOffsets(sunX: 0, y: [.sun: 0, .back: 0, .front: 0])
}

public struct MarkIntroPlayer: Sendable {
  private struct Track: Sendable {
    let delay: Double
    var spring: RNSpring
    var started = false
  }

  private var tracks: [MarkLayer.Name: Track]
  private var drift: Track
  private var startedAt: Double?
  public private(set) var offsets: MarkOffsets
  public var finished: Bool { tracks.values.allSatisfy(\.spring.finished) && drift.spring.finished }

  public init() {
    var tracks: [MarkLayer.Name: Track] = [:]
    var y: [MarkLayer.Name: Double] = [:]
    for layer in MarkIntro.layers {
      tracks[layer.name] = Track(delay: layer.delay, spring: RNSpring(layer.spring, from: layer.hidden))
      y[layer.name] = layer.hidden
    }
    self.tracks = tracks
    drift = Track(delay: MarkIntro.sunDelay, spring: RNSpring(MarkIntro.sunDriftSpring, from: MarkIntro.sunDrift))
    offsets = MarkOffsets(sunX: MarkIntro.sunDrift, y: y)
  }

  public mutating func start(at time: Double) {
    if startedAt == nil { startedAt = time }
  }

  @discardableResult
  public mutating func step(at time: Double) -> MarkOffsets {
    guard let startedAt else { return offsets }
    for name in MarkLayer.Name.allCases {
      guard var track = tracks[name] else { continue }
      if time - startedAt >= track.delay {
        offsets.y[name] = track.spring.step(at: time)
        track.started = true
      }
      tracks[name] = track
    }
    if time - startedAt >= drift.delay {
      offsets.sunX = drift.spring.step(at: time)
      drift.started = true
    }
    return offsets
  }
}
