import Foundation

public struct TextSelection: Sendable, Equatable {
  public var start: Int
  public var end: Int

  public init(start: Int, end: Int) {
    self.start = start
    self.end = end
  }

  public static func caret(_ at: Int) -> TextSelection { TextSelection(start: at, end: at) }
}

public struct EditContext: Sendable, Equatable {
  public var before: TextSelection
  public var after: TextSelection

  public init(before: TextSelection, after: TextSelection) {
    self.before = before
    self.after = after
  }
}

public enum InlineRules {
  public static func preventsInline(typed: String, shown: String, next: String, edit: EditContext?) -> Bool {
    let typedUnits = Array(typed.utf16)
    let old = typedUnits + Array(shown.utf16)
    let nextUnits = Array(next.utf16)
    if let edit {
      let lo = min(edit.before.start, edit.before.end)
      let hi = max(edit.before.start, edit.before.end)
      if hi <= old.count && lo >= 0 {
        if nextUnits.count < old.count && edit.after.start <= lo { return true }
        let inserted = nextUnits.count - (old.count - (hi - lo))
        if inserted >= 0 && nextUnits.starts(with: old[..<lo]) && nextUnits.reversed().starts(with: old[hi...].reversed()) {
          return codePoints(nextUnits[lo..<min(lo + inserted, nextUnits.count)]) > 1
        }
      }
    }
    if nextUnits.count > typedUnits.count && nextUnits.starts(with: typedUnits) {
      return codePoints(nextUnits[typedUnits.count...]) > 1
    }
    return onlyRemoved(old, nextUnits) || codePoints(nextUnits[...]) - codePoints(typedUnits[...]) > 1
  }

  public static func acceptsCompletion(typed: String, shown: String, selection: TextSelection) -> Bool {
    !shown.isEmpty && selection.start == selection.end && selection.start == typed.utf16.count + shown.utf16.count
  }

  static func codePoints(_ units: ArraySlice<UInt16>) -> Int {
    var count = 0
    var i = units.startIndex
    while i < units.endIndex {
      let u = units[i]
      if UTF16.isLeadSurrogate(u), i + 1 < units.endIndex, UTF16.isTrailSurrogate(units[i + 1]) { i += 2 } else { i += 1 }
      count += 1
    }
    return count
  }

  static func onlyRemoved(_ from: [UInt16], _ next: [UInt16]) -> Bool {
    if next.count >= from.count { return false }
    var head = 0
    while head < next.count && next[head] == from[head] { head += 1 }
    var tail = 0
    while tail < next.count - head && next[next.count - 1 - tail] == from[from.count - 1 - tail] { tail += 1 }
    return head + tail >= next.count
  }
}
