import Foundation
import Testing

@testable import SolaraOmnibox

@Suite struct UrlTests {
  @Test func resolveInputTurnsTypedTextIntoAURL() {
    #expect(resolveInput("apple.com") == "https://apple.com")
    #expect(resolveInput("localhost:3000") == "http://localhost:3000")
    #expect(resolveInput("192.168.1.1/admin") == "http://192.168.1.1/admin")
    #expect(resolveInput("https://x.com/home") == "https://x.com/home")
    #expect(resolveInput("about:blank") == "about:blank")
    #expect(resolveInput("how to cook rice") == "https://www.google.com/search?q=how%20to%20cook%20rice")
    #expect(resolveInput("react") == "https://www.google.com/search?q=react")
    #expect(resolveInput("   ") == "")
  }

  @Test func fixupPortsIPv6LocalNamesSchemesAndFilePaths() {
    #expect(fixupUrl("example.com:8080/x") == "https://example.com:8080/x")
    #expect(fixupUrl("[::1]:8080") == "http://[::1]:8080")
    #expect(fixupUrl("printer.local") == "http://printer.local")
    #expect(fixupUrl("myapp.localhost:5173") == "http://myapp.localhost:5173")
    #expect(fixupUrl("HTTPS://Example.com/Path") == "https://Example.com/Path")
    #expect(fixupUrl("file:///Users/me/a.html") == "file:///Users/me/a.html")
    #expect(fixupUrl("/Users/me/My File.html") == "file:///Users/me/My%20File.html")
    #expect(fixupUrl("mailto:hi@example.com") == "mailto:hi@example.com")
    #expect(fixupUrl("xn--bcher-kva.example") == nil)
    #expect(fixupUrl("bücher.de") == "https://bücher.de")
    #expect(fixupUrl("en.wikipedia.org/wiki/Cat") == "https://en.wikipedia.org/wiki/Cat")
    #expect(fixupUrl("github.io") == "https://github.io")
    #expect(fixupUrl("example.co.uk") == "https://example.co.uk")
  }

  @Test func fixupLeavesSearchesAlone() {
    for text in ["index.html", "node.js", "hi@example.com", "what is apple.com", "note: buy milk", "c++", "javascript:alert(1)", "1.5", "e.g."] {
      #expect(fixupUrl(text) == nil, "\(text)")
    }
    #expect(fixupUrl("docs.internal/setup") == "http://docs.internal/setup")
    #expect(fixupUrl("site.photography/about") == "https://site.photography/about")
  }

  @Test func mixingLatinWithCyrillicOrGreekStaysPunycode() {
    #expect(displayHost("xn--pple-43d.com") == "xn--pple-43d.com")
    #expect(hostSpoofReason("xn--pple-43d.com") == .mixedScripts)
    #expect(hostSpoofReason("xn--gogle-rce.net") == .mixedScripts)
    #expect(hostSpoofReason("xn--mxa7z.com") == .mixedScripts)
  }

  @Test func wholeScriptConfusablesStayPunycodeOutsideTheirTLDs() {
    #expect(displayHost("xn--80ak6aa92e.com") == "xn--80ak6aa92e.com")
    #expect(hostSpoofReason("xn--80ak6aa92e.com") == .wholeScriptConfusable)
    #expect(displayHost("xn--80ak6aa92e.ru") == "аррӏе.ru")
    #expect(displayHost("xn--80ak6aa92e.xn--p1ai") == "аррӏе.рф")
    #expect(hostSpoofReason("xn--mxapd.com") == .wholeScriptConfusable)
    #expect(displayHost("xn--mxapd.gr") == "ικα.gr")
    #expect(hostSpoofReason("xn--yodu.com") == .wholeScriptConfusable)
    #expect(hostSpoofReason("xn--o3ce.com") == .wholeScriptConfusable)
    #expect(hostSpoofReason("xn--rbbp.com") == .wholeScriptConfusable)
  }

  @Test func dangerousPatterns() {
    #expect(hostSpoofReason("xn--ab-8j4a.com") == .dangerousPattern)
    #expect(hostSpoofReason("xn--abc-ur4b.com") == .dangerousPattern)
    #expect(hostSpoofReason("xn--lcka8k.jp") == nil)
    #expect(hostSpoofReason("xn--49j7eb.jp") == .dangerousPattern)
    #expect(hostSpoofReason("xn--abc-ss4b.jp") == .dangerousPattern)
    #expect(hostSpoofReason("xn--" + punycodeEncode("ai\u{307}b") + ".com") == .dangerousPattern)
    #expect(hostSpoofReason("xn--o-jcc.com") == .dangerousPattern)
  }

  @Test func cleanUrlDropsCampaignAndClickIdParameters() {
    #expect(cleanUrl("https://example.com/post?utm_source=newsletter&utm_medium=email&utm_campaign=fall") == "https://example.com/post")
    #expect(cleanUrl("https://example.com/?fbclid=IwAR0abc") == "https://example.com/")
    #expect(cleanUrl("https://shop.example/item?id=42&gclid=Cj0KCQ&color=red") == "https://shop.example/item?id=42&color=red")
    #expect(cleanUrl("https://news.example/a?mc_eid=123&mc_cid=456&page=2") == "https://news.example/a?page=2")
    #expect(cleanUrl("https://x.example/?_hsenc=p2A&_hsmi=1&msclkid=9") == "https://x.example/")
    #expect(cleanUrl("https://example.com/?UTM_Source=caps") == "https://example.com/")
  }

  @Test func cleanUrlKeepsTheRestOfTheURLExactlyAsItWas() {
    #expect(cleanUrl("https://example.com/a?q=a%20b&utm_source=x#section-2") == "https://example.com/a?q=a%20b#section-2")
    #expect(cleanUrl("https://example.com/a?utm_source=x#frag?utm_medium=y") == "https://example.com/a#frag?utm_medium=y")
    #expect(cleanUrl("https://example.com/search?q=utm_source") == "https://example.com/search?q=utm_source")
    #expect(cleanUrl("https://example.com/?b=2&a=1") == "https://example.com/?b=2&a=1")
    #expect(cleanUrl("https://example.com/path") == "https://example.com/path")
    #expect(cleanUrl("https://user:pw@example.com:8443/p?utm_term=x&k") == "https://user:pw@example.com:8443/p?k")
  }

  @Test func displayedURLsSayArdiaNeverChrome() {
    AppScheme.withScheme(productName: nil) {
      #expect(urlForDisplay("ardia://version/") == "ardia://version")
      #expect(urlForDisplay("chrome://version/") == "ardia://version")
      #expect(urlForDisplay("chrome://settings/languages") == "ardia://settings/languages")
      #expect(urlForDisplay("ardia://history/?q=a") == "ardia://history?q=a")
      #expect(displayUrl("chrome://gpu/") == "ardia://gpu")
      #expect(breadcrumb("ardia://version/", title: "About Version") == Breadcrumb(host: "ardia://version", trail: ["About Version"]))
      #expect(breadcrumb("ardia://history", title: "History") == Breadcrumb(host: "ardia://history", trail: []))
      #expect(breadcrumb("chrome://flags/", title: "Experiments") == Breadcrumb(host: "ardia://flags", trail: ["Experiments"]))
    }
  }

  @Test func hostPortNavigatesButANumberOrATimeNever() {
    #expect(fixupUrl("myserver:8080") == "http://myserver:8080")
    #expect(fixupUrl("localhost:3000") == "http://localhost:3000")
    #expect(fixupUrl("devbox:3000/api/health?x=1") == "http://devbox:3000/api/health?x=1")
    #expect(fixupUrl("foo.zzzz:8080") == "https://foo.zzzz:8080")
    #expect(resolveInput("myserver:8080") == "http://myserver:8080")
    for text in ["10:30", "3:2", "8080", "12:30pm", "ratio 3:2", "note: 5", "a:b", "std::vector"] { #expect(fixupUrl(text) == nil, "\(text)") }
  }

  @Test func idnHostsNavigateInAnyScript() {
    #expect(fixupUrl("münchen.de") == "https://münchen.de")
    #expect(fixupUrl("Яндекс.рф") == "https://Яндекс.рф")
    #expect(fixupUrl("яндекс.рф/search?text=x") == "https://яндекс.рф/search?text=x")
    #expect(fixupUrl("例え.jp") == "https://例え.jp")
    #expect(fixupUrl("bücher.example/x/") == "https://bücher.example/x/")
    #expect(fixupUrl("xn--bcher-kva.de") == "https://xn--bcher-kva.de")
    #expect(fixupUrl("café.fr:8443") == "https://café.fr:8443")
    #expect(fixupUrl("café") == nil)
    #expect(fixupUrl("münchen.zzzz") == nil)
    #expect(fixupUrl("naïve bayes.com") == nil)
  }

  @Test func anUnknownTLDSearchesUnlessThePathSaysURL() {
    #expect(fixupUrl("foo.zzzz") == nil)
    #expect(fixupUrl("foo.zzzz/x") == nil)
    #expect(fixupUrl("foo.zzzz?x=1") == nil)
    #expect(fixupUrl("foo.zzzz#top") == nil)
    #expect(fixupUrl("foo.zzzz/") == "https://foo.zzzz/")
    #expect(fixupUrl("foo.zzzz/x/") == "https://foo.zzzz/x/")
    #expect(fixupUrl("foo.zzzz/x?y=1") == "https://foo.zzzz/x?y=1")
    #expect(fixupUrl("foo.zzzz/x#y") == "https://foo.zzzz/x#y")
    #expect(fixupUrl("x.y/") == "https://x.y/")
    #expect(fixupUrl("https://foo.zzzz/x") == "https://foo.zzzz/x")
    #expect(fixupUrl("http://foo") == "http://foo")
    #expect(fixupUrl("foo/bar") == nil)
    #expect(fixupUrl("foo/") == "http://foo/")
    #expect(fixupUrl("wiki/Main?x=1") == "http://wiki/Main?x=1")
    #expect(fixupUrl("react") == nil)
    #expect(fixupUrl("and/or") == nil)
  }

  @Test func aKnownRegistryNavigates() {
    for text in ["site.photography/about", "docs.new", "report.zip", "shop.bike", "hello.world", "a.xn--p1ai", "b.中国", "c.рф"] { #expect(fixupUrl(text) != nil, "\(text)") }
    for text in ["index.html", "node.js", "e.g.", "1.5", "a.b", "c++", "v1.2.3", "file.txt", "README.md.bak", "hi@example.com"] { #expect(fixupUrl(text) == nil, "\(text)") }
  }

  @Test func randomHostsKnownTLDOrPortNavigates() {
    var seed: UInt32 = 7
    func rnd(_ n: Int) -> Int {
      seed = seed &* 1_664_525 &+ 1_013_904_223
      return Int(seed % UInt32(n))
    }
    func pick<T>(_ list: [T]) -> T { list[rnd(list.count)] }
    let tlds = JS.splitSpaces(Units(pslTlds)).map(\.string).filter { $0.utf16.count > 1 && $0 != "local" && $0 != "localhost" }
    let labels = ["a", "foo", "my-site", "x1", "münchen", "яндекс", "例え", "9lives", "a-b-c"]
    for _ in 0..<3000 {
      let host = "\(pick(labels))\(rnd(3) != 0 ? "" : ".\(pick(labels))").\(pick(tlds))"
      let tail = pick(["", "/", "/x", "/x/y?z=1", ":8080", ":8080/x", "?q=1", "#t"])
      let url = fixupUrl(host + tail)
      #expect(url.map { $0.utf16.reversed().starts(with: (host + tail).utf16.reversed()) } == true, "\(host)\(tail) → \(url ?? "nil")")
      #expect(fixupUrl(JS.trimEnd("\(host) \(tail)".units).string + " x") == nil, "a space makes it prose")
      let unknown = "\(pick(labels)).\(pick(["zzzz", "qqqq", "notatld"]))"
      #expect(fixupUrl(unknown + pick(["", "/x", "?q=1", "#t"])) == nil, "\(unknown)")
      #expect(fixupUrl("\(unknown):\(1 + rnd(65535))") != nil, "a port makes it a URL")
    }
  }
}

@Suite struct AppSchemeTests {
  @Test func upstreamKeepsArdiaUntilAProductNameIsSet() {
    AppScheme.withScheme(productName: nil) {
      #expect(appScheme() == "ardia")
      #expect(urlForDisplay("chrome://version/") == "ardia://version")
      #expect(fixupUrl("ardia://version") == "ardia://version")
    }
  }

  @Test func theSchemeIsTheProductNameLowercasedAndNeverOneTheEngineOwns() {
    #expect(appSchemeFor("Solara") == "solara")
    #expect(appSchemeFor("My Browser") == "mybrowser")
    #expect(appSchemeFor("Chrome") == "ardia")
    #expect(appSchemeFor("HTTP") == "ardia")
    #expect(appSchemeFor("42") == "ardia")
    #expect(appSchemeFor("") == "ardia")
    #expect(appSchemeFor(nil) == "ardia")
  }

  @Test func aForkDisplaysChromeAndArdiaPagesUnderItsOwnScheme() {
    AppScheme.withScheme(productName: "Solara") {
      #expect(appScheme() == "solara")
      #expect(urlForDisplay("chrome://version/") == "solara://version")
      #expect(urlForDisplay("ardia://version/") == "solara://version")
      #expect(urlForDisplay("solara://history/?q=a") == "solara://history?q=a")
      #expect(displayUrl("chrome://gpu/") == "solara://gpu")
      #expect(toAppUrl("view-source:chrome://version") == "view-source:solara://version")
      #expect(toAppUrl("about:flags") == "solara://flags")
      #expect(appUrlOrigin("ardia://settings/sync") == "solara://settings")
      #expect(breadcrumb("chrome://flags/", title: "Experiments") == Breadcrumb(host: "solara://flags", trail: ["Experiments"]))
      #expect(breadcrumb("solara://history", title: "History") == Breadcrumb(host: "solara://history", trail: []))
    }
  }

  @Test func aForksTypedSchemeArdiaAndChromeAllResolveAndReachTheEngineAsChrome() {
    AppScheme.withScheme(productName: "Solara") {
      for typed in ["solara://version", "ardia://version", "chrome://version", "SOLARA://version"] {
        #expect(fixupUrl(typed) == "solara://version", "\(typed)")
        #expect(resolveInput(typed) == "solara://version", "\(typed)")
      }
      #expect(toEngineUrl("solara://version") == "chrome://version")
      #expect(toEngineUrl("ardia://flags/#x") == "chrome://flags/#x")
      #expect(toEngineUrl("view-source:solara://version") == "view-source:chrome://version")
      #expect(toEngineUrl("https://solara.example/") == "https://solara.example/")
    }
  }

  @Test func aForkRoutesItsOwnPagesFromEitherScheme() {
    AppScheme.withScheme(productName: "Solara") {
      #expect(appUrlRoute("solara://history") == .page(.history))
      #expect(appUrlRoute("ardia://bookmarks") == .page(.bookmarks))
      #expect(appUrlRoute("solara://settings/sync") == .settings(section: "sync"))
      #expect(appUrlRoute("solara://newtab") == .newTab)
      #expect(appUrlRoute("solara://version") == .engine(url: "chrome://version"))
      #expect(appUrlRoute("chrome://version") == nil)
    }
  }

  @Test func setAppSchemeReturnsTheSchemeItSets() {
    #expect(setAppScheme(nil) == "ardia")
    #expect(appScheme() == "ardia")
  }
}

@Suite struct SanitizePasteTests {
  @Test func aURLWrappedOverLinesJoinsWithNothingBetween() {
    #expect(sanitizePaste("https://ex\nample.com/a") == "https://example.com/a")
    #expect(sanitizePaste("https://ex\r\n  ample.com") == "https://example.com")
  }

  @Test func proseWithLineBreaksJoinsWithASpace() {
    #expect(sanitizePaste("a b\nc") == "a b c")
    #expect(sanitizePaste("one two\n\n three") == "one two three")
  }

  @Test func leadingAndTrailingWhitespaceGoesInnerSpacesStay() {
    #expect(sanitizePaste("  https://x.com/\n  path  \n") == "https://x.com/path")
    #expect(sanitizePaste("one  two\n") == "one  two")
  }

  @Test func emptyAndAllWhitespacePastes() {
    #expect(sanitizePaste("") == "")
    #expect(sanitizePaste("\n\n") == " ")
    #expect(sanitizePaste("plain") == "plain")
  }
}
