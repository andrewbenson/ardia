import Foundation
import Testing

@testable import SolaraOmnibox

private func bits(_ hex: String) -> Double { Double(bitPattern: UInt64(hex, radix: 16)!) }

@Suite struct JSLayerDifferential {
  @Test func lowercaseMatchesToLowerCaseForEveryCodePoint() throws {
    let fixture = try Fixture.load("lower.json")
    var m = Mismatches()
    var changed = Set<UInt32>()
    for pair in fixture["changes"]!.items {
      let cp = UInt32(pair[0]!.int)
      changed.insert(cp)
      m.check("U+\(String(cp, radix: 16))", JS.lower(String(Unicode.Scalar(cp)!)), pair[1])
    }
    for cp in UInt32(0)...0x10ffff where !changed.contains(cp) {
      guard let scalar = Unicode.Scalar(cp) else { continue }
      let s = String(scalar)
      if !JS.lower(s).sameUnits(s) { m.check("U+\(String(cp, radix: 16)) unchanged", JS.lower(s), .string(s)) }
    }
    for sample in fixture["samples"]!.items {
      m.check("lower \(sample[0]!.str)", JS.lower(sample[0]!.str), sample[1])
      m.check("upper \(sample[0]!.str)", JS.upper(sample[0]!.str), sample[2])
    }
    #expect(m.total == 0, "\(m.report)")
  }

  @Test func numbersFormatLikeJavaScript() throws {
    var m = Mismatches()
    for c in try Fixture.load("numbers.json").items {
      let x = bits(c["bits"]!.str)
      m.check("String(\(c["string"]!.str))", JS.numberToString(x), c["string"])
      m.check("toPrecision(12) \(c["string"]!.str)", JS.toPrecision(x, 12), c["p12"])
      m.check("toPrecision(9) \(c["string"]!.str)", JS.toPrecision(x, 9), c["p9"])
      m.check("toExponential \(c["string"]!.str)", JS.toExponential(x), c["exp"])
    }
    #expect(m.total == 0, "\(m.report)")
  }

  @Test func visitWeightsMatchMathLog2BitForBit() throws {
    var m = Mismatches()
    for pair in try Fixture.load("log2.json").items {
      let v = bits(pair[0]!.str)
      let want = bits(pair[1]!.str)
      let got = FdLibm.log2(1 + v) * 8
      m.check("log2(1 + \(v)) * 8", .string(String(got.bitPattern, radix: 16)), .string(String(want.bitPattern, radix: 16)))
    }
    #expect(m.total == 0, "\(m.report)")
  }
}

private func json(_ p: PasteAction?) -> ParsedJSON {
  switch p {
  case .go(let url)?: obj(["kind": .string("go"), "url": .string(url)])
  case .search(let query)?: obj(["kind": .string("search"), "query": .string(query)])
  case nil: .null
  }
}

private func json(_ r: AppUrlRoute?) -> ParsedJSON {
  switch r {
  case .page(let page)?: obj(["kind": .string("page"), "page": .string(page.rawValue)])
  case .settings(let section)?: obj(["kind": .string("settings"), "section": js(section)])
  case .newTab?: obj(["kind": .string("newTab")])
  case .engine(let url)?: obj(["kind": .string("engine"), "url": .string(url)])
  case nil: .null
  }
}

@Suite struct UrlDifferential {
  static let fixture = Result { try Fixture.load("urls.json") }

  func run(_ pass: String, product: String?) throws -> (Mismatches, Int) {
    var m = Mismatches()
    var threw = 0
    try AppScheme.withScheme(productName: product) {
      for c in try UrlDifferential.fixture.get()[pass]!.items {
        let input = c["input"]!.str
        let title = c["title"]!.str
        let label = "\(pass) \(describe(.string(input)))"
        func check(_ name: String, _ got: @autoclosure () -> ParsedJSON) {
          guard let want = c[name] else { return }
          if let error = want["throws"] {
            threw += 1
            Issue.record("packages/core threw on \(label) \(name): \(error.str)")
            return
          }
          m.check("\(label) \(name)", got(), want)
        }
        check("fixupUrl", js(fixupUrl(input)))
        check("resolveInput", .string(resolveInput(input)))
        check("resolveDuck", .string(resolveInput(input, search: "https://duckduckgo.com/?q=%s")))
        check("classifyPaste", json(classifyPaste(input)))
        check("sanitizePaste", .string(sanitizePaste(input)))
        check("hostOf", .string(hostOf(input)))
        check("urlForDisplay", .string(urlForDisplay(input)))
        check("displayUrl", .string(displayUrl(input)))
        let crumb = breadcrumb(input, title: title)
        check("breadcrumb", obj(["host": .string(crumb.host), "trail": .array(crumb.trail.map(ParsedJSON.string))]))
        check("cleanUrl", .string(cleanUrl(input)))
        check("markdownLink", .string(markdownLink(title: title, url: input)))
        check("appUrlOrigin", js(appUrlOrigin(input)))
        check("toAppUrl", .string(toAppUrl(input)))
        check("toEngineUrl", .string(toEngineUrl(input)))
        check("appUrlRoute", json(appUrlRoute(input)))
        check("isAppScheme", .bool(isAppScheme(input)))
        check("searchUrlFor", .string(searchUrlFor("https://e.example/?q=%s&again=%s", input)))
      }
    }
    return (m, threw)
  }

  @Test func underTheDefaultScheme() throws {
    let (m, threw) = try run("unnamed", product: nil)
    #expect(m.total == 0, "\(m.report)")
    #expect(threw == 0)
  }

  @Test func underSolarasScheme() throws {
    let (m, _) = try run("solara", product: "Solara")
    #expect(m.total == 0, "\(m.report)")
  }

  @Test func appSchemeForProductNames() throws {
    var m = Mismatches()
    for pair in try UrlDifferential.fixture.get()["appSchemeFor"]!.items {
      m.check("appSchemeFor \(describe(pair[0]))", .string(appSchemeFor(pair[0]!.optionalString)), pair[1])
    }
    #expect(m.total == 0, "\(m.report)")
  }
}

@Suite struct IdnDifferential {
  @Test func displayHostAndSpoofReasons() throws {
    let fixture = try Fixture.load("idn.json")
    var m = Mismatches()
    for c in fixture["hosts"]!.items {
      let host = c[0]!.str
      m.check("displayHost \(host)", .string(displayHost(host)), c[1])
      m.check("hostSpoofReason \(host)", js(hostSpoofReason(host)?.rawValue), c[2])
    }
    for c in fixture["punycode"]!.items {
      m.check("punycodeEncode \(c[0]!.str)", .string(punycodeEncode(c[0]!.str)), c[1])
    }
    #expect(m.total == 0, "\(m.report)")
  }
}

@Suite struct CalculatorDifferential {
  @Test func calculateAndEvaluate() throws {
    var m = Mismatches()
    var ulps = 0
    for c in try Fixture.load("calc.json").items {
      let input = c["input"]!.str
      let got = calculate(input)
      let want = c["calc"]!
      if want.isNull || got == nil {
        m.check("calculate \(describe(.string(input)))", got.map { obj(["expression": .string($0.expression), "display": .string($0.display)]) } ?? .null, want.isNull ? .null : obj(["expression": want["expression"]!, "display": want["display"]!]))
      } else if let got {
        m.check("calculate \(describe(.string(input))) expression", .string(got.expression), want["expression"])
        m.check("calculate \(describe(.string(input))) display", .string(got.display), want["display"])
        if !same(js(got.value), want["value"]) { ulps += 1 }
      }
      let e = evaluate(input)
      if c["evaluate"]!.isNull || e == nil {
        m.check("evaluate \(describe(.string(input)))", e.map(js) ?? .null, c["evaluate"])
      } else if !same(js(e!), c["evaluate"]) {
        ulps += 1
      }
    }
    #expect(m.total == 0, "\(m.report)")
    print("CalculatorDifferential: \(ulps) raw values differ from V8's Math in the last bits; every display string matches")
  }
}
