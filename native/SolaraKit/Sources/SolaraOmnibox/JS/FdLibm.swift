import Foundation

enum FdLibm {
  private static let two54 = 1.80143985094819840000e+16
  private static let ivln2hi = 1.44269504072144627571e+00
  private static let ivln2lo = 1.67517131648865118353e-10
  private static let lg1 = 6.666666666666735130e-01
  private static let lg2 = 3.999999999940941908e-01
  private static let lg3 = 2.857142874366239149e-01
  private static let lg4 = 2.222219843214978396e-01
  private static let lg5 = 1.818357216161805012e-01
  private static let lg6 = 1.531383769920937332e-01
  private static let lg7 = 1.479819860511658591e-01

  private static func high(_ x: Double) -> Int32 { Int32(truncatingIfNeeded: x.bitPattern >> 32) }
  private static func low(_ x: Double) -> UInt32 { UInt32(truncatingIfNeeded: x.bitPattern) }

  private static func withHigh(_ x: Double, _ hi: Int32) -> Double {
    Double(bitPattern: UInt64(UInt32(bitPattern: hi)) << 32 | (x.bitPattern & 0xffff_ffff))
  }

  private static func withLow(_ x: Double, _ lo: UInt32) -> Double {
    Double(bitPattern: (x.bitPattern & 0xffff_ffff_0000_0000) | UInt64(lo))
  }

  private static func kLog1p(_ f: Double) -> Double {
    let s = f / (2.0 + f)
    let z = s * s
    let w = z * z
    let t1 = w * (lg2 + w * (lg4 + w * lg6))
    let t2 = z * (lg1 + w * (lg3 + w * (lg5 + w * lg7)))
    let r = t2 + t1
    let hfsq = 0.5 * f * f
    return s * (hfsq + r)
  }

  static func log2(_ input: Double) -> Double {
    var x = input
    var hx = high(x)
    let lx = low(x)
    var k: Int32 = 0
    if hx < 0x0010_0000 {
      if (hx & 0x7fff_ffff) | Int32(bitPattern: lx) == 0 { return -Double.infinity }
      if hx < 0 { return .nan }
      k -= 54
      x *= two54
      hx = high(x)
    }
    if hx >= 0x7ff0_0000 { return x + x }
    if hx == 0x3ff0_0000 && lx == 0 { return 0 }
    k += (hx >> 20) - 1023
    hx &= 0x000f_ffff
    let i = (hx &+ 0x95f64) & 0x10_0000
    x = withHigh(x, hx | (i ^ 0x3ff0_0000))
    k += i >> 20
    let y = Double(k)
    let f = x - 1.0
    let hfsq = 0.5 * f * f
    let r = kLog1p(f)
    let hi = withLow(f - hfsq, 0)
    let lo = (f - hi) - hfsq + r
    var valHi = hi * ivln2hi
    var valLo = (lo + hi) * ivln2lo + lo * ivln2hi
    let w = y + valHi
    valLo += (y - w) + valHi
    valHi = w
    return valLo + valHi
  }
}
