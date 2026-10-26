import Foundation
import Testing

@testable import SolaraOmnibox

private func heliumFile(_ entries: [String]) -> String {
  let filler = (0..<1000).map { "{\"s\": \"Site \($0)\", \"ts\": [\"site\($0)\"], \"u\": \"https://site\($0).example/?q={searchTerms}\",\n}" }
  return "// Generated at 2026-10-14T11:11:02.825Z\n// MIT License\n//\n\n[\n" + (entries + filler).joined(separator: ",\n") + ",\n]\n"
}

private let fixture = slimBangs(
  heliumFile([
    #"{"s": "GitHub", "ts": ["gh", "git", "github"], "u": "https://github.com/search?q={searchTerms}"}"#,
    #"{"s": "GitHub Repo", "ts": ["ghr"], "f": 1, "u": "https://github.com/{searchTerms}"}"#,
    #"{"s": "Wikipedia", "ts": ["w", "wiki"], "u": "https://wikipedia.org/w/index.php?search={searchTerms}"}"#,
    #"{"s": "YouTube", "ts": ["yt", "ют"], "u": "https://www.youtube.com/results?search_query={searchTerms}"}"#,
    #"{"s": "Zig", "ts": ["zig"], "u": "https://ziglang.org/documentation/master/std/#?{searchTerms}"}"#,
    #"{"s": "Gmail", "ts": ["gmail"], "u": "https://mail.google.com/mail/u/0/#search/{searchTerms}"}"#,
    #"{"s": "T3 Chat", "ts": ["t3"], "u": "https://www.t3.chat/new?q={searchTerms}", "sc": "ai"}"#,
    #"{"s": "Microsoft Copilot", "ts": ["copilot"], "u": "https://copilot.microsoft.com/?q={searchTerms}"}"#,
    #"{"s": "DuckDuckGo AI Chat", "ts": ["ddg-chat"], "u": "https://duckduckgo.com/?q={searchTerms}&ia=chat&bang=true"}"#,
    #"{"s": "Not a web page", "ts": ["ftp"], "u": "ftp://example.com/{searchTerms}"}"#,
    #"{"s": "Read the Docs", "ts": ["rtfd"], "u": "https://{searchTerms}.rtfd.io/"}"#,
    #"{"s": "hypestat", "ts": ["hypestat"], "u": "https://www.{searchTerms}.hypestat.com/"}"#,
    #"{"s": "No slash", "ts": ["noslash"], "u": "https://example.com{searchTerms}"}"#,
    #"{"s": "Port", "ts": ["port"], "u": "https://example.com:{searchTerms}/"}"#,
    #"{"s": "User", "ts": ["user"], "u": "https://{searchTerms}@example.com/"}"#,
    #"{"s": "Taken", "ts": ["gh"], "u": "https://taken.example/?q={searchTerms}"}"#,
  ])
)!

private let table = bangTable(fixture)
private func url(_ text: String) -> String? { findBang(text, table)?.url }

private struct OneBang: BangTable {
  var size: Int { 1 }
  func get(_ trigger: String) -> Bang? { Bang(trigger: "x", name: "X", template: "https://x.example{searchTerms}", home: "https://x.example/") }
}

@Suite struct BangTests {
  @Test func aBangAtTheStartOrTheEndPicksTheSiteAnyCase() {
    #expect(url("!gh react") == "https://github.com/search?q=react")
    #expect(url("react !w") == "https://wikipedia.org/w/index.php?search=react")
    #expect(url("!GH react hooks") == "https://github.com/search?q=react+hooks")
    #expect(url("  react   hooks   !Wiki ") == "https://wikipedia.org/w/index.php?search=react+hooks")
    #expect(url("!ют cats") == "https://www.youtube.com/results?search_query=cats")
    #expect(findBang("!gh react", table)?.bang == Bang(trigger: "gh", name: "GitHub", template: "https://github.com/search?q={searchTerms}", home: "https://github.com/"))
  }

  @Test func aBareBangOpensTheSitesHome() {
    #expect(url("!yt") == "https://www.youtube.com/")
    #expect(url("  !W  ") == "https://wikipedia.org/")
  }

  @Test func anUnknownBangALoneBangOrABangInsideAWordIsNoBang() {
    for text in ["!nope react", "react !nope", "hello!", "wow ! nice", "!", "! gh react", "hi!gh", "say !gh in the middle", "example.com/!gh", "?!gh react", "a!w"] {
      #expect(findBang(text, table) == nil, "\(text)")
    }
    #expect(findBang("!gh react", nil) == nil)
  }

  @Test func theFirstMatchingEndWinsAndTheOtherBangStaysInTheQuery() {
    #expect(url("!gh react !w") == "https://github.com/search?q=react+!w")
    #expect(url("!nope react !w") == "https://wikipedia.org/w/index.php?search=!nope+react")
  }

  @Test func termsAfterTheQuestionMarkAreEscapedAsAQueryParameter() {
    #expect(url("!gh a+b & c/d #x 100%") == "https://github.com/search?q=a%2Bb+%26+c%2Fd+%23x+100%25")
    #expect(url("!gh 日本 語") == "https://github.com/search?q=%E6%97%A5%E6%9C%AC+%E8%AA%9E")
    #expect(url("!gh it's (ok)*!~") == "https://github.com/search?q=it's+(ok)*!~")
    #expect(url("!zig std.mem a b") == "https://ziglang.org/documentation/master/std/#?std.mem+a+b")
  }

  @Test func termsInThePathKeepSlashesAndEscapeWhatWouldEndThePath() {
    #expect(url("!ghr facebook/react") == "https://github.com/facebook/react")
    #expect(url("!ghr a b?c#d%e") == "https://github.com/a%20b%3Fc%23d%25e")
    #expect(url("!gmail from:me") == "https://mail.google.com/mail/u/0/#search/from%3Ame")
    #expect(escapeSearchTerms("é ü", inQuery: false) == "%C3%A9%20%C3%BC")
    #expect(escapeSearchTerms("a\u{FFFD}b", inQuery: true) == "a%EF%BF%BDb")
    #expect(fillBangTemplate("https://a.example/{searchTerms}/x?q={searchTerms}", "p q") == "https://a.example/p%20q/x?q=p%20q")
  }

  @Test func aTemplateWithTheTermsInItsSchemeHostPortOrUserIsLeftOut() {
    for t in ["rtfd", "hypestat", "noslash", "port", "user"] { #expect(table.get(t) == nil, "\(t)") }
    for text in ["!rtfd evil.example/", "!hypestat @evil.example/", "!rtfd evil.example#", "!rtfd evil.example\\", "!hypestat //evil.example", "!rtfd evil.example%2F", "!rtfd", "!noslash @evil.example"] {
      #expect(findBang(text, table) == nil, "\(text)")
    }
    let stored = bangTable("rtfd\tRead the Docs\t{s}.rtfd.io/\nhs\thypestat\twww.{s}.hypestat.com/\nus\tUser\t{s}@example.com/")
    for t in ["rtfd", "hs", "us"] { #expect(stored.get(t) == nil, "\(t)") }
  }

  @Test func theResolvedURLMustKeepTheTemplatesSchemeHostAndPort() {
    #expect(staysOnSite("https://github.com/search?q=a", "https://github.com/search?q={searchTerms}"))
    #expect(staysOnSite("https://GitHub.com/a", "https://github.com/{searchTerms}"))
    #expect(staysOnSite("https://github.com\\@evil.example/", "https://github.com/{searchTerms}"))
    for u in ["https://github.com@evil.example/", "https://evil.example/github.com/", "http://github.com/a", "https://github.com:444/a", "https://github.com.evil.example/", "https://github.com/a\tb", "https://github.com/a\nb"] {
      #expect(!staysOnSite(u, "https://github.com/{searchTerms}"), "\(u)")
    }
    #expect(findBang("!x @evil.example", OneBang()) == nil)
    #expect(findBang("!x", OneBang()) == nil)
  }

  @Test func questionMarkForcesAPlainSearchEvenWithABang() {
    for text in ["?!gh react", "?!gh react !w", "? react !w", "  ?react !w"] { #expect(findBang(text, table) == nil, "\(text)") }
  }

  @Test func templatesThatArentWebPagesAreLeftOutAndATriggerKeepsItsFirstSite() {
    #expect(table.get("ftp") == nil)
    #expect(table.get("t3")?.name == "T3 Chat")
    #expect(url("!copilot hi") == "https://copilot.microsoft.com/?q=hi")
    #expect(table.get("gh")?.name == "GitHub")
  }

  @Test func heliumsFileFormatCommentsTrailingCommasAndSlashesInsideStrings() throws {
    let a = ParsedJSON(try parseLooseJson("// head\n[\n {\"u\": \"https://a//b\", /* c */ \"ts\": [\"x\",],},\n // tail\n]\n"))
    #expect(a == .array([.object([("u", .string("https://a//b")), ("ts", .array([.string("x")]))])]))
    let b = ParsedJSON(try parseLooseJson(#"["a\\", "b,]", "c\"//"]"#))
    #expect(b == .array([.string("a\\"), .string("b,]"), .string("c\"//")]))
  }

  @Test func aStoredListIsCheckedWhole() {
    #expect(checkedBangTable(fixture) != nil)
    let broken = (0..<1200).map { "bad\($0)\tBroken\thttps://bad host/" }.joined(separator: "\n")
    #expect(checkedBangTable(broken) == nil)
    #expect(checkedBangTable("\(fixture)\nbad\tBroken\thttps://bad host/") == nil)
    #expect(checkedBangTable("\(fixture)\nbad\tBroken") == nil)
    #expect(checkedBangTable("\(fixture)\nbad\tBroken\tx.example/{s}\textra") == nil)
    #expect(checkedBangTable(fixture.components(separatedBy: "\n").filter { !$0.hasPrefix("yt ") }.joined(separator: "\n")) == nil)
    #expect(checkedBangTable(fixture.components(separatedBy: "\n").prefix(900).joined(separator: "\n")) == nil)
    #expect(checkedBangTable("\(fixture)\n\(String(repeating: "x", count: 4_000_000))\tBig\tbig.example/{s}") == nil)
  }

  @Test func theStoredDocumentCarriesItsETagWithTheListItBelongsTo() {
    let doc = bangDocument(etag: "\"v2\"", slim: fixture)
    #expect(readBangDocument(doc)?.etag == "\"v2\"")
    #expect(readBangDocument(doc)?.table.get("gh")?.name == "GitHub")
    #expect(readBangDocument(bangDocument(etag: nil, slim: fixture)) != nil)
    #expect(readBangDocument(bangDocument(etag: nil, slim: fixture))?.etag == nil)
    for bad in [nil, "", fixture, String(doc.prefix(2000)), "ardia-bangs 2\t\"v2\"\n\(fixture)", "ardia-bangs 1\t\"v2\"\tx\n\(fixture)"] {
      #expect(readBangDocument(bad) == nil)
    }
  }

  @Test func aBrokenEmptyOrTinyResponseIsNotABangList() {
    let tiny = String(heliumFile([]).prefix(5000))
    for body in ["", "<html>oops</html>", "{}", "[]", #"[{"s":"A","ts":["a"],"u":"https://a.example/{searchTerms}"}]"#, tiny] {
      #expect(slimBangs(body) == nil, "\(body.prefix(40))")
    }
  }

  @Test func theBundledListHasTheCommonBangs() {
    #expect(BundledBangs.list.utf8.allSatisfy { $0 < 0x80 })
    #expect(BundledBangs.table.size > 13000, "\(BundledBangs.table.size)")
    #expect(findBang("!ют cats", BundledBangs.table)?.url == "https://www.youtube.com/results?search_query=cats")
    #expect(findBang("!gh react", BundledBangs.table)?.url == "https://github.com/search?q=react")
    #expect(findBang("react !w", BundledBangs.table)?.url == "https://wikipedia.org/w/index.php?search=react")
    #expect(findBang("!yt", BundledBangs.table)?.url == "https://www.youtube.com/")
    #expect(BundledBangs.table.get("t3")?.name == "T3 Chat")
    #expect(BundledBangs.etag == "\"6ad9e8e9-512a8\"")
  }

  @Test func theCommandBarsTopRowIsTheBangsSearchThenTheSitesPagesFromHistory() {
    let source = SuggestionSource(history: [
      HistoryRow(url: "https://github.com/facebook/react", title: "facebook/react", favicon: nil, visits: 9, lastVisit: 1),
      HistoryRow(url: "https://react.dev/", title: "React", favicon: nil, visits: 30, lastVisit: 1),
    ])
    let result = buildSuggestions("!gh react", source, SuggestOptions(now: 2, remote: ["react native"], bangs: table))
    #expect(result.items == [
      .search(query: "react", url: "https://github.com/search?q=react", engine: "GitHub", bang: true),
      .page(url: "https://github.com/facebook/react", title: "facebook/react", favicon: nil, visited: true),
    ])
    #expect(result.completion == "")
    #expect(buildSuggestions("!yt", source, SuggestOptions(bangs: table)).items == [.page(url: "https://www.youtube.com/", title: "YouTube", favicon: nil)])
    #expect(buildSuggestions("hello!", source, SuggestOptions(bangs: table)).items.first?.kind == "search")
    #expect(!buildSuggestions("!gh react", source, SuggestOptions(bangs: nil)).items.contains { if case .search(_, _, _, _, true) = $0 { true } else { false } })
    let scoped = buildSuggestions("!gh react", source, SuggestOptions(scope: SearchScope(kind: .site, name: "X", host: "x.com", url: "https://x.com/search?q=%s"), bangs: table))
    if case .search(_, let url, _, _, _)? = scoped.items.first { #expect(url == "https://x.com/search?q=!gh%20react") } else { Issue.record("no search row") }
  }
}
