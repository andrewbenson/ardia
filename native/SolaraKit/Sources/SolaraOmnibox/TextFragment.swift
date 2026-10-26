import Foundation

public struct TextFragment: Sendable, Equatable {
  public var prefix: String?
  public var start: String
  public var end: String?
  public var suffix: String?

  public init(prefix: String? = nil, start: String, end: String? = nil, suffix: String? = nil) {
    self.prefix = prefix
    self.start = start
    self.end = end
    self.suffix = suffix
  }
}

public struct SelectionContext: Sendable, Equatable {
  public var selected: String
  public var before: String
  public var after: String
  public var pageText: String

  public init(selected: String, before: String, after: String, pageText: String) {
    self.selected = selected
    self.before = before
    self.after = after
    self.pageText = pageText
  }
}

private let maxExactWords = 10
private let rangeWords = 3
private let maxContextWords = 5

private func normalize(_ s: Units) -> Units { JS.trim(JS.collapseSpaces(s)) }

private func wordsOf(_ s: Units) -> [Units] {
  normalize(s).split(separator: Unit.space).map(Array.init)
}

private func occurrences(_ haystack: Units, _ needle: Units) -> Int {
  if needle.isEmpty { return 0 }
  var count = 0
  var i = haystack.index(of: needle)
  while let at = i {
    count += 1
    i = haystack.index(of: needle, from: at + 1)
  }
  return count
}

private let wordEnd = Pattern("[\\p{L}\\p{N}_]+\\z")
private let wordStart = Pattern("^[\\p{L}\\p{N}_]+")

private func toWordBoundaries(_ c: SelectionContext) -> (selected: Units, before: Units, after: Units, pageText: Units) {
  let selected = c.selected.units
  let before = c.before.units
  let after = c.after.units
  let head = wordStart.test(selected) ? (wordEnd.firstMatch(before)?[0] ?? []) : []
  let tail = wordEnd.test(selected) ? (wordStart.firstMatch(after)?[0] ?? []) : []
  return (head + selected + tail, Array(before[..<(before.count - head.count)]), Array(after[tail.count...]), c.pageText.units)
}

private func splitBlocks(_ s: Units) -> [Units] {
  var blocks: [Units] = []
  var start = 0
  var i = 0
  while i < s.count {
    if JS.isSpace(s[i]) {
      var end = i
      var hasNewline = false
      while end < s.count && JS.isSpace(s[end]) {
        if s[end] == Unit.newline { hasNewline = true }
        end += 1
      }
      if hasNewline {
        blocks.append(Array(s[start..<i]))
        start = end
      }
      i = end
    } else {
      i += 1
    }
  }
  blocks.append(Array(s[start...]))
  return blocks
}

private func joinWords(_ words: some Collection<Units>) -> Units { Array(words.joined(separator: [Unit.space])) }

private func last<T>(_ list: [T], _ n: Int) -> ArraySlice<T> { n <= 0 ? list[...] : list.suffix(n) }

public func chooseTextFragment(_ context: SelectionContext) -> TextFragment? {
  let (selected, before, after, pageText) = toWordBoundaries(context)
  let blocks = splitBlocks(selected).map(normalize).filter { !$0.isEmpty }
  if blocks.isEmpty { return nil }
  let page = JS.lower(normalize(pageText))
  let count = { (text: Units) in occurrences(page, JS.lower(text)) }
  let all = blocks.flatMap(wordsOf)
  let beforeWords = wordsOf(before)
  let afterWords = wordsOf(after)

  if blocks.count == 1 && all.count <= maxExactWords {
    let start = joinWords(all)
    if count(start) <= 1 { return TextFragment(start: start.string) }
    var n = 1
    while true {
      let prefix = joinWords(last(beforeWords, n))
      let suffix = joinWords(afterWords.prefix(n))
      let exhausted = n >= maxContextWords || n >= max(beforeWords.count, afterWords.count)
      if exhausted || count(joinWords([prefix, start, suffix].filter { !$0.isEmpty })) <= 1 {
        return TextFragment(prefix: prefix.isEmpty ? nil : prefix.string, start: start.string, suffix: suffix.isEmpty ? nil : suffix.string)
      }
      n += 1
    }
  }
  let first = wordsOf(blocks[0])
  let lastBlock = wordsOf(blocks[blocks.count - 1])
  let most = blocks.count == 1 ? all.count / 2 : min(first.count, lastBlock.count)
  var n = min(rangeWords, most)
  while n < most && count(joinWords(first.prefix(n))) > 1 { n += 1 }
  let start = joinWords(first.prefix(max(n, 0)))
  let end = joinWords(last(lastBlock, n))
  if count(start) <= 1 || beforeWords.isEmpty { return TextFragment(start: start.string, end: end.string) }
  return TextFragment(prefix: joinWords(last(beforeWords, rangeWords)).string, start: start.string, end: end.string)
}

private func encodeTerm(_ s: String) -> String {
  JS.encodeURIComponent(s).replacingOccurrences(of: "-", with: "%2D")
}

private func textDirective(_ f: TextFragment) -> String {
  let parts = [
    f.prefix.flatMap { $0.isEmpty ? nil : encodeTerm($0) + "-" },
    encodeTerm(f.start),
    f.end.flatMap { $0.isEmpty ? nil : encodeTerm($0) },
    f.suffix.flatMap { $0.isEmpty ? nil : "-" + encodeTerm($0) },
  ]
  return "text=" + parts.compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ",")
}

public func withTextFragment(_ url: String, _ fragment: TextFragment) -> String {
  let u = url.units
  let hash = u.firstIndex(of: Unit.hash)
  let base = hash.map { Array(u[..<$0]) } ?? u
  var ref = hash.map { Array(u[($0 + 1)...]) } ?? []
  if let directive = ref.index(of: Units(":~:")) { ref = Array(ref[..<directive]) }
  return base.string + "#" + ref.string + ":~:" + textDirective(fragment)
}
