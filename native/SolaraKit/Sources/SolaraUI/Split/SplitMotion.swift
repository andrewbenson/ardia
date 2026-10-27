import Foundation

extension SpringParams {
  static func rn(speed: Double, bounciness: Double) -> SpringParams {
    func friction(_ x: Double) -> Double {
      if x <= 18 { return 0.0007 * pow(x, 3) - 0.031 * pow(x, 2) + 0.64 * x + 1.28 }
      if x <= 44 { return 0.000044 * pow(x, 3) - 0.006 * pow(x, 2) + 0.36 * x + 2 }
      return 0.00000045 * pow(x, 3) - 0.000332 * pow(x, 2) + 0.1078 * x + 5.84
    }
    let b = bounciness / 1.7 / 20 * 0.8
    let tension = 0.5 + speed / 1.7 / 20 * 199.5
    let t = 2 * b - b * b
    let bouncy = t * 0.01 + (1 - t) * friction(tension)
    return SpringParams(stiffness: (tension - 30) * 3.62 + 194, damping: (bouncy - 8) * 3 + 25)
  }
}
