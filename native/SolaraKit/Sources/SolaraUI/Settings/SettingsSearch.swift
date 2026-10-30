import Foundation

public struct SettingsSearchHit: Sendable, Equatable {
  public let entry: SettingEntry
  public let score: Double
}

public struct SettingsSearchGroup: Sendable, Equatable {
  public let pane: SettingsPane
  public let hits: [SettingsSearchHit]
}

public enum SettingsSearch {
  enum Field: CaseIterable {
    case title, keywords, section, paneTitle, description

    var weight: Double {
      switch self {
      case .title: 10
      case .keywords: 8
      case .section: 5
      case .paneTitle: 4
      case .description: 2
      }
    }
  }

  static let exact = 1.0
  static let plural = 0.95
  static let prefix = 0.85
  static let inside = 0.45
  static let typo = 0.55
  static let minScore = 1.8

  private static let keptSymbols: Set<Unicode.Scalar> = ["⌘", "⌥", "⇧", "⌃"]

  public static func normalize(_ text: String) -> String {
    let decomposed = text.decomposedStringWithCompatibilityMapping
    var out = String.UnicodeScalarView()
    var pendingSpace = false
    for scalar in decomposed.unicodeScalars {
      if (0x300...0x36F).contains(scalar.value) { continue }
      if scalar == "’" || scalar == "'" { continue }
      let lowered = String(scalar).lowercased().unicodeScalars
      for s in lowered {
        let kept = ("a"..."z").contains(s) || ("0"..."9").contains(s) || keptSymbols.contains(s)
        if kept {
          if pendingSpace, !out.isEmpty { out.append(" ") }
          pendingSpace = false
          out.append(s)
        } else {
          pendingSpace = true
        }
      }
    }
    return String(out)
  }

  static func words(_ text: String) -> [String] {
    normalize(text).split(separator: " ").map(String.init)
  }

  public static func editDistance(_ a: String, _ b: String, limit: Int) -> Int {
    let a = Array(a.unicodeScalars)
    let b = Array(b.unicodeScalars)
    if abs(a.count - b.count) > limit { return limit + 1 }
    var prev2: [Int] = []
    var prev = Array(0...b.count)
    if a.isEmpty { return prev[b.count] }
    for i in 1...a.count {
      var row = [i]
      var best = i
      if !b.isEmpty {
        for j in 1...b.count {
          let cost = a[i - 1] == b[j - 1] ? 0 : 1
          var d = min(prev[j] + 1, row[j - 1] + 1, prev[j - 1] + cost)
          if i > 1, j > 1, a[i - 1] == b[j - 2], a[i - 2] == b[j - 1] { d = min(d, prev2[j - 2] + 1) }
          row.append(d)
          best = min(best, d)
        }
      }
      if best > limit { return limit + 1 }
      prev2 = prev
      prev = row
    }
    return prev[b.count]
  }

  static func typoLimit(_ token: String) -> Int {
    let n = token.unicodeScalars.count
    return n >= 8 ? 2 : n >= 4 ? 1 : 0
  }

  static func tokenMatch(_ token: String, _ word: String) -> Double {
    if word == token { return exact }
    if word == token + "s" || token == word + "s" || word == token + "es" || token == word + "es" { return plural }
    if word.hasPrefix(token) { return prefix }
    let tokenLength = token.unicodeScalars.count
    let wordLength = word.unicodeScalars.count
    if tokenLength >= 3, word.contains(token) { return inside }
    let limit = typoLimit(token)
    if limit == 0 || wordLength < 3 { return 0 }
    if editDistance(token, word, limit: limit) <= limit { return typo }
    if wordLength > tokenLength {
      let head = String(String.UnicodeScalarView(word.unicodeScalars.prefix(tokenLength)))
      if editDistance(token, head, limit: limit) <= limit, token.unicodeScalars.first == word.unicodeScalars.first { return typo * 0.9 }
    }
    return 0
  }

  public struct Prepared: Sendable {
    let entry: SettingEntry
    let fields: [(field: Field, words: [String], phrase: String)]
  }

  public static func prepare(_ entries: [SettingEntry]) -> [Prepared] {
    entries.map { entry in
      let texts: [(Field, String)] = [
        (.title, entry.title),
        (.keywords, entry.keywords.joined(separator: " ")),
        (.section, entry.section),
        (.paneTitle, entry.paneTitle),
        (.description, [entry.caption, entry.description].compactMap { $0 }.joined(separator: " ")),
      ]
      return Prepared(entry: entry, fields: texts.map { ($0.0, words($0.1), normalize($0.1)) })
    }
  }

  static func score(_ p: Prepared, tokens: [String], phrase: String) -> Double {
    var total = 0.0
    for token in tokens {
      var best = 0.0
      for field in p.fields {
        for word in field.words {
          let quality = tokenMatch(token, word)
          if quality > 0, field.field.weight * quality > best { best = field.field.weight * quality }
        }
      }
      if best == 0 { return 0 }
      total += best
    }
    let title = p.fields[0].phrase
    let pane = p.fields[3].phrase
    if pane == phrase || pane.hasPrefix(phrase) || (phrase.hasPrefix(pane) && phrase.unicodeScalars.count - pane.unicodeScalars.count <= 1) { total += 6 }
    if title == phrase { total += 12 }
    else if title.hasPrefix(phrase) { total += 8 }
    else if " \(title) ".contains(" \(phrase) ") { total += 5 }
    else if tokens.count > 1, title.contains(phrase) { total += 3 }
    else if " \(p.fields[1].phrase) ".contains(" \(phrase) ") { total += 4 }
    let count = Double(tokens.count)
    return total / count + (tokens.count > 1 ? total / 40 : 0)
  }

  public static func search(_ index: [Prepared], _ query: String, limit: Int = 40) -> [SettingsSearchHit] {
    let phrase = normalize(query)
    let tokens = phrase.split(separator: " ").map(String.init)
    if tokens.isEmpty { return [] }
    var hits: [(offset: Int, hit: SettingsSearchHit)] = []
    for (offset, p) in index.enumerated() {
      let s = score(p, tokens: tokens, phrase: phrase)
      if s >= minScore { hits.append((offset, SettingsSearchHit(entry: p.entry, score: s))) }
    }
    hits.sort { $0.hit.score != $1.hit.score ? $0.hit.score > $1.hit.score : $0.offset < $1.offset }
    let top = hits.first?.hit.score ?? 0
    return Array(hits.map(\.hit).filter { $0.score >= top * 0.3 }.prefix(limit))
  }

  public static func groupByPane(_ hits: [SettingsSearchHit]) -> [SettingsSearchGroup] {
    var order: [SettingsPane] = []
    var groups: [SettingsPane: [SettingsSearchHit]] = [:]
    for hit in hits {
      if groups[hit.entry.pane] == nil { order.append(hit.entry.pane) }
      groups[hit.entry.pane, default: []].append(hit)
    }
    return order.map { SettingsSearchGroup(pane: $0, hits: groups[$0]!) }
  }
}
