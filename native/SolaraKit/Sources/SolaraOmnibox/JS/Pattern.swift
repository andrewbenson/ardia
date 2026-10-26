import Foundation

final class Pattern: @unchecked Sendable {
  struct Match {
    let units: Units
    let ranges: [NSRange]

    var range: NSRange { ranges[0] }
    var end: Int { NSMaxRange(ranges[0]) }

    subscript(group: Int) -> Units? {
      let r = ranges[group]
      return r.location == NSNotFound ? nil : Array(units[r.location..<NSMaxRange(r)])
    }
  }

  private let regex: NSRegularExpression

  init(_ pattern: String) {
    regex = try! NSRegularExpression(pattern: pattern, options: [])
  }

  private static func nsString(_ units: Units) -> NSString {
    units.withUnsafeBufferPointer { NSString(characters: $0.baseAddress ?? UnsafePointer(bitPattern: 1)!, length: $0.count) }
  }

  func firstMatch(_ units: Units, from start: Int = 0) -> Match? {
    let ns = Pattern.nsString(units)
    guard start <= units.count,
      let m = regex.firstMatch(in: ns as String, options: [.withoutAnchoringBounds], range: NSRange(location: start, length: units.count - start))
    else { return nil }
    return Match(units: units, ranges: (0..<m.numberOfRanges).map { m.range(at: $0) })
  }

  func test(_ units: Units) -> Bool {
    let ns = Pattern.nsString(units)
    return regex.firstMatch(in: ns as String, options: [.withoutAnchoringBounds], range: NSRange(location: 0, length: units.count)) != nil
  }

  func test(_ s: String) -> Bool { test(s.units) }

  func matches(_ units: Units) -> [Match] {
    let ns = Pattern.nsString(units)
    return regex.matches(in: ns as String, options: [.withoutAnchoringBounds], range: NSRange(location: 0, length: units.count)).map { m in
      Match(units: units, ranges: (0..<m.numberOfRanges).map { m.range(at: $0) })
    }
  }
}
