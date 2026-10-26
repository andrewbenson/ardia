import Foundation

public protocol ActionCandidate: Sendable {
  var id: String { get }
  var title: String { get }
  var keywords: [String]? { get }
}

public struct ActionMatch<T: ActionCandidate>: Sendable {
  public var action: T
  public var score: Double
  public var exact: Bool
}

private func wordsOf(_ lower: Units) -> [Units] {
  lower.split(whereSeparator: { !Unit.isLowerAlnum($0) }).map(Array.init)
}

private func isSubsequence(_ needle: Units, _ haystack: Units) -> Bool {
  var from = 0
  for c in needle {
    guard from <= haystack.count, let at = haystack[from...].firstIndex(of: c) else { return false }
    from = at + 1
  }
  return true
}

private func alnumOnly(_ t: Units) -> Units { t.filter(Unit.isLowerAlnum) }

public func fuzzyScore(_ query: String, _ text: String) -> Double {
  let q = JS.lower(JS.trim(query.units))
  let t = JS.lower(text.units)
  if q.isEmpty { return 0 }
  if t == q { return 1000 }
  let tw = wordsOf(t)
  var score: Double = t.hasPrefix(q) ? 200 : 0
  for token in wordsOf(q) {
    if let i = tw.firstIndex(where: { $0.hasPrefix(token) }) {
      score += Double(60 + token.count * 4 - i * 2)
    } else if token.count >= 3 && t.contains(token) {
      score += Double(25 + token.count)
    } else if token.count >= 2 && isSubsequence(token, alnumOnly(t)) {
      score += 8
    } else {
      return 0
    }
  }
  return score - Double(tw.count)
}

struct PreparedName {
  let lower: Units
  let words: [Units]
  let plain: Units

  init(_ text: String) {
    lower = JS.lower(text.units)
    words = wordsOf(lower)
    plain = alnumOnly(lower)
  }
}

struct PreparedAction {
  let names: [PreparedName]

  init(title: String, keywords: [String]?) {
    names = ([title] + (keywords ?? [])).map(PreparedName.init)
  }
}

private func scoreName(_ q: Units, _ tokens: [Units], _ n: PreparedName) -> Double {
  let t = n.lower
  if t == q { return 1000 }
  let tw = n.words
  var score: Double = t.hasPrefix(q) ? 200 : 0
  for token in tokens {
    var i = 0
    while i < tw.count && !tw[i].hasPrefix(token) { i += 1 }
    if i < tw.count {
      score += Double(60 + token.count * 4 - i * 2)
    } else if token.count >= 3 && t.contains(token) {
      score += Double(25 + token.count)
    } else if token.count >= 2 && isSubsequence(token, n.plain) {
      score += 8
    } else {
      return 0
    }
  }
  return score - Double(tw.count)
}

func matchPrepared<T: ActionCandidate>(_ query: String, _ actions: [T], _ prepared: [PreparedAction], limit: Int) -> [ActionMatch<T>] {
  let q = JS.collapseSpaces(JS.lower(JS.trim(query.units)))
  if q.count < 2 { return [] }
  let tokens = wordsOf(q)
  var hits: [(match: ActionMatch<T>, order: Int)] = []
  for a in actions.indices {
    let list = prepared[a].names
    var score = -Double.infinity
    var exact = false
    for (i, n) in list.enumerated() {
      if n.lower == q { exact = true }
      let s = scoreName(q, tokens, n) - (i > 0 ? 5 : 0)
      if s > score { score = s }
    }
    if score > 0 { hits.append((ActionMatch(action: actions[a], score: score, exact: exact), a)) }
  }
  hits.sort { $0.match.score != $1.match.score ? $0.match.score > $1.match.score : $0.order < $1.order }
  return hits.prefix(max(limit, 0)).map(\.match)
}

public func matchActions<T: ActionCandidate>(_ query: String, _ actions: [T], limit: Int = 3) -> [ActionMatch<T>] {
  matchPrepared(query, actions, actions.map { PreparedAction(title: $0.title, keywords: $0.keywords) }, limit: limit)
}

public final class ActionIndex<T: ActionCandidate>: Sendable {
  public let actions: [T]
  let prepared: [PreparedAction]

  public init(_ actions: [T]) {
    self.actions = actions
    prepared = actions.map { PreparedAction(title: $0.title, keywords: $0.keywords) }
  }

  public func match(_ query: String, limit: Int = 3) -> [ActionMatch<T>] {
    matchPrepared(query, actions, prepared, limit: limit)
  }
}
