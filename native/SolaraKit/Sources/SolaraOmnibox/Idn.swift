import Foundation
import Synchronization

private let base = 36
private let tMin = 1
private let tMax = 26
private let skew = 38
private let damp = 700
private let initialBias = 72
private let initialN = 128
private let maxCodePoint = 0x10ffff

private func adapt(_ delta: Int, _ points: Int, _ first: Bool) -> Int {
  var delta = first ? delta / damp : delta >> 1
  delta += delta / points
  var k = 0
  while delta > ((base - tMin) * tMax) >> 1 {
    delta /= base - tMin
    k += base
  }
  return k + ((base - tMin + 1) * delta) / (delta + skew)
}

private func digitValue(_ c: UInt16) -> Int {
  switch c {
  case 0x30...0x39: Int(c) - 22
  case 0x41...0x5a: Int(c) - 0x41
  case 0x61...0x7a: Int(c) - 0x61
  default: base
  }
}

private func digitChar(_ d: Int) -> Character {
  Character(Unicode.Scalar(UInt8(d < 26 ? d + 0x61 : d + 22)))
}

private func threshold(_ k: Int, _ bias: Int) -> Int {
  k <= bias ? tMin : k >= bias + tMax ? tMax : k - bias
}

func punycodeDecode(_ input: Units) -> String? {
  var output: [Int] = []
  let delimiter = input.lastIndex(of: Unit.dash) ?? -1
  for j in 0..<max(delimiter, 0) {
    let c = input[j]
    if c >= 0x80 { return nil }
    output.append(Int(c))
  }
  var n = initialN
  var bias = initialBias
  var i = 0
  var index = delimiter > 0 ? delimiter + 1 : 0
  while index < input.count {
    let oldI = i
    var w = 1
    var k = base
    while true {
      if index >= input.count { return nil }
      let digit = digitValue(input[index])
      index += 1
      if digit >= base || digit > (maxCodePoint - i) / w { return nil }
      i += digit * w
      let t = threshold(k, bias)
      if digit < t { break }
      w *= base - t
      k += base
    }
    let points = output.count + 1
    bias = adapt(i - oldI, points, oldI == 0)
    n += i / points
    i %= points
    if n > maxCodePoint || (n >= 0xd800 && n <= 0xdfff) { return nil }
    output.insert(n, at: i)
    i += 1
  }
  var scalars = String.UnicodeScalarView()
  for cp in output {
    guard let scalar = Unicode.Scalar(UInt32(cp)) else { return nil }
    scalars.append(scalar)
  }
  return String(scalars)
}

public func punycodeEncode(_ input: String) -> String {
  let points = input.unicodeScalars.map { Int($0.value) }
  var output = String(String.UnicodeScalarView(points.filter { $0 < 0x80 }.map { Unicode.Scalar(UInt8($0)) }))
  let basic = output.utf16.count
  var handled = basic
  if basic > 0 { output += "-" }
  var n = initialN
  var delta = 0
  var bias = initialBias
  while handled < points.count {
    let m = points.filter { $0 >= n }.min()!
    delta += (m - n) * (handled + 1)
    n = m
    for c in points {
      if c < n { delta += 1 }
      if c != n { continue }
      var q = delta
      var k = base
      while true {
        let t = threshold(k, bias)
        if q < t { break }
        output.append(digitChar(t + (q - t) % (base - t)))
        q = (q - t) / (base - t)
        k += base
      }
      output.append(digitChar(q))
      bias = adapt(delta, handled + 1, handled == basic)
      delta = 0
      handled += 1
    }
    delta += 1
    n += 1
  }
  return output
}

private let scriptNames = [
  "Latin", "Greek", "Cyrillic", "Armenian", "Hebrew", "Arabic", "Thaana", "Devanagari", "Bengali", "Gurmukhi",
  "Gujarati", "Oriya", "Tamil", "Telugu", "Kannada", "Malayalam", "Sinhala", "Thai", "Lao", "Tibetan", "Myanmar",
  "Georgian", "Hangul", "Ethiopic", "Khmer", "Hiragana", "Katakana", "Bopomofo", "Han",
]

private func scx(_ name: String) -> String { "\\p{Script_Extensions=\(name)}" }

private let scriptTests = scriptNames.map { ($0, Pattern(scx($0))) }
private let commonScript = Pattern("[\\p{Script=Common}\\p{Script=Inherited}]")
private let identifier = Pattern("^[\\p{Ll}\\p{Lo}\\p{Lm}\\p{Mn}\\p{Mc}\\p{Nd}-]\\z")
private let excluded = Pattern(
  "[" +
    "\\u0138\\u0149\\u017f\\u01c4-\\u01cc\\u01dd\\u0180-\\u019f\\u01a2-\\u01ae\\u01b1-\\u01cc\\u01f1-\\u01f3\\u01f6\\u01f7" +
    "\\u021c\\u021d\\u0220-\\u0225\\u0234-\\u024f" +
    "\\u0250-\\u0258\\u025a-\\u02ff" +
    "\\u0305\\u030d\\u030e\\u0310\\u0312\\u0315-\\u031a\\u031c-\\u0322\\u0329-\\u032c\\u032f\\u0332-\\u0334\\u0336\\u0337\\u033a-\\u036f" +
    "\\u0370-\\u038f\\u03cf-\\u03ff\\u1f00-\\u1fff" +
    "\\u0482-\\u0489" +
    "\\u1d00-\\u1dbf\\u1dc0-\\u1dff\\u2c60-\\u2c7f\\ua720-\\ua7ff\\uab30-\\uab6f" +
    "\\u10a0-\\u10cf\\u1c90-\\u1cbf" +
    "\\u0964\\u0965\\u0970\\u0e2f\\u0e46\\u0eaf\\u0ec6\\u0f01-\\u0f1f\\u0f2a-\\u0f3f\\u104a-\\u104f\\u17d4-\\u17d6\\u17d8-\\u17db" +
    "\\u3031-\\u3035\\u303b\\u303c\\u3099\\u309a\\u309b\\u309c\\u309f\\u30a0\\u30ff\\u3131-\\u318e" +
    "]"
)
private let allowedCommon = Pattern(
  "^[-\\u00b7\\u30fb\\u30fc\\u3005-\\u3007\\u0300-\\u0304\\u0306-\\u030c\\u030f\\u0311\\u0313\\u0314\\u031b\\u0323-\\u0328\\u032d\\u032e\\u0330\\u0331\\u0335\\u0338\\u0339]\\z"
)
private let mark = Pattern("\\p{M}")
private let decimalDigit = Pattern("\\p{Nd}")

private let allowedCache = Mutex<[UInt32: Bool]>([:])
private let scriptsCache = Mutex<[UInt32: [String]?]>([:])

private func isAllowed(_ c: String) -> Bool {
  let key = c.unicodeScalars.first!.value
  if let cached = allowedCache.withLock({ $0[key] }) { return cached }
  let allowed = computeAllowed(c)
  allowedCache.withLock { $0[key] = allowed }
  return allowed
}

private func computeAllowed(_ c: String) -> Bool {
  let u = c.units
  if allowedCommon.test(u) { return true }
  if !identifier.test(u) || excluded.test(u) { return false }
  if !c.precomposedStringWithCompatibilityMapping.sameUnits(c) || !JS.lower(c).sameUnits(c) { return false }
  return scriptsOf(c) != nil
}

private func scriptsOf(_ c: String) -> [String]? {
  let key = c.unicodeScalars.first!.value
  if let cached = scriptsCache.withLock({ $0[key] }) { return cached }
  let scripts = computeScripts(c)
  scriptsCache.withLock { $0[key] = .some(scripts) }
  return scripts
}

private func computeScripts(_ c: String) -> [String]? {
  let u = c.units
  let scripts = scriptTests.filter { $0.1.test(u) }.map(\.0)
  if !scripts.isEmpty { return scripts }
  return commonScript.test(u) ? [] : nil
}

private func augmented(_ scripts: [String]) -> Set<String> {
  var set = Set(scripts)
  if set.contains("Han") { set.formUnion(["Hanb", "Jpan", "Kore"]) }
  if set.contains("Hiragana") || set.contains("Katakana") { set.insert("Jpan") }
  if set.contains("Hangul") { set.insert("Kore") }
  if set.contains("Bopomofo") { set.insert("Hanb") }
  return set
}

private enum Restriction { case ascii, single, highly, moderately, minimal }

private func intersect(_ list: [Set<String>]) -> Set<String>? {
  var acc: Set<String>?
  for s in list { acc = acc.map { $0.intersection(s) } ?? s }
  return acc
}

private func restrictionLevel(_ chars: [String]) -> Restriction {
  if chars.allSatisfy({ $0.utf16.first! < 0x80 }) { return .ascii }
  let sets = chars.map { augmented(scriptsOf($0) ?? []) }.filter { !$0.isEmpty }
  let all = intersect(sets)
  if all == nil || !all!.isEmpty { return .single }
  guard let nonLatin = intersect(sets.filter { !$0.contains("Latin") }), !nonLatin.isEmpty else { return .minimal }
  if ["Hanb", "Jpan", "Kore"].contains(where: nonLatin.contains) { return .highly }
  if !nonLatin.contains("Cyrillic") && !nonLatin.contains("Greek") { return .moderately }
  return .minimal
}

private func isDecimalDigit(_ cp: UInt32) -> Bool {
  guard let scalar = Unicode.Scalar(cp) else { return false }
  return decimalDigit.test(String(scalar).units)
}

private func digitSystems(_ chars: [String]) -> Set<UInt32> {
  var zeros = Set<UInt32>()
  for c in chars where decimalDigit.test(c.units) {
    let cp = c.unicodeScalars.first!.value
    var zero = cp
    while zero > 0 && isDecimalDigit(zero - 1) && cp - zero < 9 { zero -= 1 }
    zeros.insert(zero)
  }
  return zeros
}

private let deviations = Pattern("[\\u00df\\u03c2\\u200c\\u200d]")
private let digitLookalikes = Pattern("[θ२২੨૨೩೭Շзҙӡउওਤ੩૩౩ဒვპ੫丩ㄐճ৪੪୫૭୨౨]")
private let kanaExceptions = Pattern("[\\u3078-\\u307a\\u30d8-\\u30da\\u30fb-\\u30fe]")
private let combiningDiacritics = Pattern("[\\u0300-\\u0339]")
private let nonAsciiLatin = Pattern("(?![a-z])\\p{Script=Latin}")
private let lgcOrAscii = Pattern("^[\\p{Script=Latin}\\p{Script=Greek}\\p{Script=Cyrillic}0-9._\\u0300-\\u0339-]*\\z")
private let asciiDigit = Pattern("[0-9]")
private let thornOrEth = Pattern("[þð]")
private let unsafeMiddleDot = Pattern("[^l]·|·[^l]|^·|·\\z")

private struct WholeScript {
  let script: Pattern
  let lookalikes: Pattern
  let tlds: [String]
}

private let wholeScriptConfusables: [WholeScript] = [
  WholeScript(script: Pattern("\\p{Script=Armenian}"), lookalikes: Pattern("[ագզէլհյնոսւօՙ]"), tlds: ["am"]),
  WholeScript(script: Pattern("\\p{Script=Cyrillic}"), lookalikes: Pattern("[асԁеһіјӏорԗԛѕԝхуъЬҽпгѵѡ]"), tlds: ["bg", "by", "kz", "pyc", "ru", "su", "ua", "uz"]),
  WholeScript(script: Pattern("\\p{Script=Ethiopic}"), lookalikes: Pattern("[ሀሁሃሠሡሰሱሲቀቁበቡነኑኒከኮዐዑዕዖፀፁፐ]"), tlds: ["er", "et"]),
  WholeScript(script: Pattern("\\p{Script=Georgian}"), lookalikes: Pattern("[იოყჽ]"), tlds: ["ge"]),
  WholeScript(script: Pattern("\\p{Script=Greek}"), lookalikes: Pattern("[αικνρυωϲοτχ]"), tlds: ["gr"]),
  WholeScript(script: Pattern("\\p{Script=Hebrew}"), lookalikes: Pattern("[דוחיןסם]"), tlds: ["il"]),
  WholeScript(script: Pattern("\\p{Script=Khmer}"), lookalikes: Pattern("[ឧ]"), tlds: ["kh"]),
  WholeScript(script: Pattern("\\p{Script=Lao}"), lookalikes: Pattern("[ບປຍຮຣຨຫອພຟຝ໐]"), tlds: ["la"]),
  WholeScript(script: Pattern("\\p{Script=Sinhala}"), lookalikes: Pattern("[ථ]"), tlds: ["lk"]),
  WholeScript(script: Pattern("\\p{Script=Thai}"), lookalikes: Pattern("[ทนบพรหเแ๐ดลปฟม]"), tlds: ["th"]),
]

private let dangerous: Pattern = {
  let kana = scx("Katakana") + scx("Hiragana") + scx("Han")
  return Pattern(
    [
      "[^\(kana)][\\u30ce\\u30f3\\u30bd\\u30be\\u4e36\\u4e40\\u4e41\\u4e3f]",
      "[\\u30ce\\u30f3\\u30bd\\u30be\\u4e36\\u4e40\\u4e41\\u4e3f][^\(kana)]",
      "^[\(scx("Katakana"))]+[\\u3078-\\u307a][\(scx("Katakana"))]+\\z",
      "^[\(scx("Hiragana"))]+[\\u30d8-\\u30da][\(scx("Hiragana"))]+\\z",
      "[^\(scx("Katakana"))\(scx("Hiragana"))]\\u30fc|^\\u30fc",
      "[^\(scx("Katakana"))][\\u30fd\\u30fe]|^[\\u30fd\\u30fe]",
      "[a-z]\\u30fb|\\u30fb[a-z]",
      "[^\(scx("Han"))]\\u4e00|\\u4e00[^\(scx("Han"))]",
      "[^\(scx("Bopomofo"))]\\u3127|\\u3127[^\(scx("Bopomofo"))]",
      "[^\(scx("Latin"))\(scx("Greek"))\(scx("Cyrillic"))][\\u0300-\\u0339]",
      "\\u0131[\\u0300-\\u0339]",
      "[ijl\\u0131]\\u0307",
      "[a-z][\\u0585\\u0581]|[\\u0585\\u0581][a-z]",
      "[\(scx("Armenian"))][og]|[og][\(scx("Armenian"))]",
      "[^\(scx("Arabic"))][\\u064b-\\u0652\\u0670]",
      "[^\(scx("Hebrew"))]\\u05b4",
    ].joined(separator: "|")
  )
}()

public enum SpoofReason: String, Sendable, Equatable {
  case invalid, disallowedCharacter, invisible, mixedNumbers, mixedScripts, deviationCharacter, tldSpecificCharacter,
    unsafeMiddleDot, digitLookalikes, wholeScriptConfusable, nonAsciiLatinMixed, dangerousPattern, topDomainLookalike
}

private func labelSpoofReason(_ label: String, _ tld: String) -> SpoofReason? {
  let chars = label.unicodeScalars.map { String($0) }
  let u = label.units
  if chars.isEmpty { return .invalid }
  if !chars.allSatisfy(isAllowed) { return .disallowedCharacter }
  for i in chars.indices.dropFirst() where chars[i].sameUnits(chars[i - 1]) && mark.test(chars[i].units) { return .invisible }
  if digitSystems(chars).count > 1 { return .mixedNumbers }
  let level = restrictionLevel(chars)
  if level == .minimal { return .mixedScripts }
  if deviations.test(u) { return .deviationCharacter }
  if chars.count > 1 && !tld.sameUnits("is") && thornOrEth.test(u) { return .tldSpecificCharacter }
  if chars.count > 1 && !tld.sameUnits("az") && u.contains(Units("ə")) { return .tldSpecificCharacter }
  if u.contains(Units("·")) && (!tld.sameUnits("cat") || unsafeMiddleDot.test(u)) { return .unsafeMiddleDot }
  if level == .ascii { return nil }
  if digitLookalikes.test(u) && chars.allSatisfy({ asciiDigit.test($0.units) || digitLookalikes.test($0.units) }) { return .digitLookalikes }
  if level == .single && !kanaExceptions.test(u) && !combiningDiacritics.test(u) {
    let unicodeTld = decodeLabel(tld.units) ?? tld
    for confusable in wholeScriptConfusables {
      let letters = chars.filter { confusable.script.test($0.units) }
      if letters.isEmpty || !letters.allSatisfy({ confusable.lookalikes.test($0.units) }) { continue }
      let tldUsesScript = unicodeTld.unicodeScalars.allSatisfy { confusable.script.test(String($0).units) }
      if !confusable.tlds.contains(where: { $0.sameUnits(tld) }) && !tldUsesScript { return .wholeScriptConfusable }
    }
    return nil
  }
  if nonAsciiLatin.test(u) && !lgcOrAscii.test(u) { return .nonAsciiLatinMixed }
  if dangerous.test(u) { return .dangerousPattern }
  return nil
}

private func decodeLabel(_ label: Units) -> String? {
  guard label.asciiCaseInsensitivePrefix("xn--") else { return nil }
  let ascii = JS.lower(Array(label[4...]))
  guard let unicode = punycodeDecode(ascii), !unicode.utf16.allSatisfy({ $0 < 0x80 }) else { return nil }
  if !unicode.precomposedStringWithCanonicalMapping.sameUnits(unicode) || !JS.lower(unicode).sameUnits(unicode) { return nil }
  if !punycodeEncode(unicode).units.elementsEqual(ascii) { return nil }
  return unicode
}

private let topDomains = (
  "google.com youtube.com facebook.com instagram.com twitter.com x.com whatsapp.com wikipedia.org amazon.com " +
    "apple.com icloud.com microsoft.com live.com outlook.com office.com bing.com linkedin.com netflix.com yahoo.com " +
    "reddit.com tiktok.com github.com gitlab.com paypal.com ebay.com dropbox.com adobe.com spotify.com twitch.tv " +
    "discord.com slack.com zoom.us notion.so figma.com openai.com chatgpt.com anthropic.com claude.ai stripe.com " +
    "shopify.com coinbase.com binance.com kraken.com blockchain.com metamask.io chase.com bankofamerica.com " +
    "wellsfargo.com citi.com americanexpress.com capitalone.com hsbc.com barclays.co.uk santander.com revolut.com " +
    "wise.com venmo.com cash.app booking.com airbnb.com expedia.com uber.com lyft.com doordash.com walmart.com " +
    "target.com bestbuy.com costco.com etsy.com aliexpress.com alibaba.com temu.com shein.com baidu.com qq.com " +
    "weibo.com yandex.ru vk.com mail.ru ok.ru naver.com kakao.com line.me rakuten.co.jp yahoo.co.jp amazon.co.jp " +
    "amazon.co.uk amazon.de amazon.fr amazon.in bbc.co.uk bbc.com cnn.com nytimes.com theguardian.com " +
    "washingtonpost.com wsj.com bloomberg.com reuters.com forbes.com medium.com substack.com wordpress.com " +
    "blogger.com tumblr.com pinterest.com quora.com stackoverflow.com imdb.com steampowered.com steamcommunity.com " +
    "epicgames.com roblox.com playstation.com xbox.com nintendo.com ea.com battle.net salesforce.com atlassian.com " +
    "trello.com asana.com canva.com docusign.com okta.com cloudflare.com godaddy.com squarespace.com wix.com " +
    "mozilla.org duckduckgo.com proton.me protonmail.com gmail.com googledrive.com fedex.com ups.com usps.com dhl.com " +
    "fidelity.com schwab.com vanguard.com robinhood.com etrade.com morganstanley.com goldmansachs.com jpmorgan.com " +
    "usbank.com pnc.com truist.com tdbank.com citibank.com discover.com ally.com sofi.com chime.com usaa.com " +
    "navyfederal.org ameriprise.com edwardjones.com merrilledge.com interactivebrokers.com webull.com " +
    "intuit.com turbotax.com creditkarma.com experian.com equifax.com transunion.com zellepay.com klarna.com " +
    "affirm.com gemini.com crypto.com bitstamp.net okx.com bybit.com kucoin.com ledger.com trezor.io " +
    "irs.gov ssa.gov gov.uk"
).split(separator: " ").map(String.init)

private let confusables: [UInt32: String] = {
  let pairs: [(String, String)] = [
    ("ø", "o"), ("đ", "d"), ("ħ", "h"), ("ı", "i"), ("ł", "l"), ("ŧ", "t"), ("ð", "d"), ("þ", "p"), ("ə", "e"), ("ß", "ss"), ("œ", "oe"), ("æ", "ae"),
    ("а", "a"), ("в", "b"), ("е", "e"), ("з", "3"), ("и", "u"), ("к", "k"), ("м", "m"), ("н", "h"), ("о", "o"), ("п", "n"), ("р", "p"), ("с", "c"), ("т", "t"), ("у", "y"),
    ("х", "x"), ("ь", "b"), ("ѕ", "s"), ("і", "i"), ("ј", "j"), ("ԁ", "d"), ("һ", "h"), ("ӏ", "l"), ("ԛ", "q"), ("ԝ", "w"), ("ҽ", "e"), ("ѵ", "v"), ("ѡ", "w"), ("г", "r"),
    ("α", "a"), ("ι", "i"), ("κ", "k"), ("ν", "v"), ("ο", "o"), ("ρ", "p"), ("τ", "t"), ("υ", "u"), ("χ", "x"), ("ω", "w"), ("ϲ", "c"),
    ("օ", "o"), ("ս", "u"), ("հ", "h"), ("ց", "g"), ("ք", "p"), ("զ", "q"), ("ո", "n"),
    ("0", "o"), ("1", "l"), ("m", "rn"), ("w", "vv"),
  ]
  var map: [UInt32: String] = [:]
  for (from, to) in pairs { map[from.unicodeScalars.first!.value] = to }
  return map
}()

private func skeleton(_ text: String) -> Units {
  let decomposed = text.decomposedStringWithCanonicalMapping
  var stripped = String.UnicodeScalarView()
  for scalar in decomposed.unicodeScalars where !mark.test(String(scalar).units) { stripped.append(scalar) }
  var out = Units()
  for scalar in JS.lower(String(stripped)).unicodeScalars {
    if let mapped = confusables[scalar.value] { out.append(contentsOf: mapped.utf16) } else { out.append(contentsOf: String(scalar).utf16) }
  }
  return out
}

private let topSkeletons: [Units: Units] = {
  var map: [Units: Units] = [:]
  for domain in topDomains { map[skeleton(domain)] = domain.units }
  return map
}()

private let wwwDot = Units("www.")

private func similarTopDomain(_ host: Units) -> Units? {
  var bare = host.hasPrefix(wwwDot) ? Array(host[4...]) : host
  if bare.last == Unit.dot { bare.removeLast() }
  let labels = bare.split(separator: Unit.dot, omittingEmptySubsequences: false).map(Array.init)
  let lastTwo = Array(labels.suffix(2)).joined(separator: [Unit.dot])
  let lastThree = Array(labels.suffix(3)).joined(separator: [Unit.dot])
  for candidate in [bare, Array(lastTwo), Array(lastThree)] {
    if let match = topSkeletons[skeleton(candidate.string)], match != candidate { return match }
  }
  return nil
}

private let displayHostCache = Mutex<[Units: Units]>([:])

private func hasPunycodeLabel(_ host: Units, caseInsensitive: Bool) -> Bool {
  var at = 0
  while at <= host.count - 4 {
    if at == 0 || host[at - 1] == Unit.dot {
      if caseInsensitive ? host.asciiCaseInsensitivePrefix("xn--", at: at) : host.hasPrefix(Units("xn--"), at: at) { return true }
    }
    at += 1
  }
  return false
}

func displayHost(_ host: Units) -> Units {
  if !hasPunycodeLabel(host, caseInsensitive: true) { return host }
  if let cached = displayHostCache.withLock({ $0[host] }) { return cached }
  let labels = JS.lower(host).split(separator: Unit.dot, omittingEmptySubsequences: false).map(Array.init)
  let last = labels[labels.count - 1]
  let tld = (!last.isEmpty ? last : labels.count >= 2 ? labels[labels.count - 2] : []).string
  var changed = false
  let shown = labels.map { label -> Units in
    guard let unicode = decodeLabel(label), labelSpoofReason(unicode, tld) == nil else { return label }
    changed = true
    return unicode.units
  }
  var result = changed ? Array(shown.joined(separator: [Unit.dot])) : host
  if changed && similarTopDomain(result) != nil { result = host }
  displayHostCache.withLock { cache in
    if cache.count > 500 { cache.removeAll() }
    cache[host] = result
  }
  return result
}

public func displayHost(_ host: String) -> String { displayHost(host.units).string }

public func hostSpoofReason(_ host: String) -> SpoofReason? {
  let lowered = JS.lower(host.units)
  let labels = lowered.split(separator: Unit.dot, omittingEmptySubsequences: false).map(Array.init)
  let tld = labels[labels.count - 1].string
  for label in labels {
    guard label.hasPrefix(Units("xn--")) else { continue }
    guard let unicode = decodeLabel(label) else { return .invalid }
    if let reason = labelSpoofReason(unicode, tld) { return reason }
  }
  return displayHost(host.units) == host.units && hasPunycodeLabel(lowered, caseInsensitive: false) ? .topDomainLookalike : nil
}
