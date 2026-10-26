import Foundation
import Testing

@testable import SolaraOmnibox

private func finiteOrNull(_ v: JSONValue) -> JSONValue {
  switch v {
  case .number(let n): n.isFinite ? .number(n == 0 ? 0 : n) : .null
  case .array(let items): .array(items.map(finiteOrNull))
  case .object(let pairs): .object(pairs.map { ($0.key, finiteOrNull($0.value)) })
  default: v
  }
}

@Suite struct BangDifferential {
  static let fixture = Result { try Fixture.load("bangs.json") }

  @Test func slimmingTablesAndLookups() throws {
    let f = try BangDifferential.fixture.get()
    var m = Mismatches()
    let slim = f["slim"]!.str
    m.check("slimBangs", js(slimBangs(f["helium"]!.str)), f["slim"])
    let table = bangTable(slim)
    m.check("size", .number(Double(table.size)), f["size"])
    for c in f["tableGets"]!.items { m.check("get \(c[0]!.str)", json(table.get(c[0]!.str)), c[1]) }
    for c in f["finds"]!.items { m.check("findBang \(describe(c[0]))", json(findBang(c[0]!.str, table)), c[1]) }
    for c in f["terms"]!.items {
      let text = c[0]!.str
      m.check("escape query \(describe(c[0]))", .string(escapeSearchTerms(text, inQuery: true)), c[1])
      m.check("escape path \(describe(c[0]))", .string(escapeSearchTerms(text, inQuery: false)), c[2])
      m.check("fill both \(describe(c[0]))", .string(fillBangTemplate("https://a.example/{searchTerms}/x?q={searchTerms}", text)), c[3])
      m.check("fill path \(describe(c[0]))", .string(fillBangTemplate("https://a.example/p/{searchTerms}", text)), c[4])
    }
    for c in f["sites"]!.items { m.check("staysOnSite \(describe(c[0])) \(describe(c[1]))", .bool(staysOnSite(c[0]!.str, c[1]!.str)), c[2]) }
    #expect(m.total == 0, "\(m.report)")
  }

  @Test func looseJsonCheckedTablesAndDocuments() throws {
    let f = try BangDifferential.fixture.get()
    var m = Mismatches()
    for c in f["loose"]!.items {
      let text = c[0]!.str
      let parsed = try? parseLooseJson(text)
      m.check("parseLooseJson ok \(describe(c[0]))", .bool(parsed != nil), c[1])
      if let parsed, c[1]!.bool {
        let got = finiteOrNull(parsed)
        if got != c[2]! { m.check("parseLooseJson \(describe(c[0]))", got, c[2]) }
      }
    }
    let slim = f["slim"]!.str
    let lines = slim.components(separatedBy: "\n")
    let variants = [
      slim, "\(slim)\nbad\tBroken\thttps://bad host/", "\(slim)\nbad\tBroken", "\(slim)\nbad\tBroken\tx.example/{s}\textra",
      lines.filter { !$0.hasPrefix("yt ") }.joined(separator: "\n"), lines.prefix(900).joined(separator: "\n"), "\(slim)\na  b\tTwo\tx.example/{s}",
      "\(slim)\n a\tLead\tx.example/{s}", "\(slim)\na!\tBang\tx.example/{s}", "\(slim)\n\tNoTrigger\tx.example/{s}", "\(slim)\n",
    ]
    for (v, c) in zip(variants, f["checked"]!.items) {
      let t = checkedBangTable(v)
      m.check("checkedBangTable length", .number(Double(v.utf16.count)), c[0])
      m.check("checkedBangTable \(v.utf16.count)", .array([.bool(t != nil), .number(Double(t?.size ?? 0))]), .array([c[1]!, c[2]!]))
    }
    let doc = bangDocument(etag: "\"v2\"", slim: slim)
    let docs = [
      doc, bangDocument(etag: nil, slim: slim), "", slim, String(units: doc.units.prefix(2000)), "ardia-bangs 2\t\"v2\"\n\(slim)",
      "ardia-bangs 1\t\"v2\"\tx\n\(slim)", "ardia-bangs 1\n\(slim)",
    ]
    for (d, c) in zip(docs, f["docs"]!.items) {
      let read = readBangDocument(d)
      m.check("readBangDocument \(c[0]!.str.prefix(30))", read.map { obj(["etag": js($0.etag), "size": .number(Double($0.table.size)), "gh": json($0.table.get("gh"))]) } ?? .null, c[1])
    }
    #expect(m.total == 0, "\(m.report)")
  }

  @Test func bundledList() throws {
    let f = try BangDifferential.fixture.get()
    var m = Mismatches()
    m.check("bundled size", .number(Double(BundledBangs.table.size)), f["bundledSize"])
    for c in f["bundledGets"]!.items { m.check("bundled get \(c[0]!.str)", json(BundledBangs.table.get(c[0]!.str)), c[1]) }
    #expect(m.total == 0, "\(m.report)")
  }
}

private struct FixtureAction: ActionCandidate {
  var id: String
  var title: String
  var keywords: [String]?
}

@Suite struct FuzzyDifferential {
  @Test func matchActionsAndFuzzyScore() throws {
    var m = Mismatches()
    for run in try Fixture.load("fuzzy.json").items {
      let actions = run["actions"]!.items.map { FixtureAction(id: $0["id"]!.str, title: $0["title"]!.str, keywords: $0["keywords"]?.items.map(\.str)) }
      let index = ActionIndex(actions)
      for q in run["queries"]!.items {
        let query = q[0]!.str
        let limit = q[1]!.int
        let got = JSONValue.array(matchActions(query, actions, limit: limit).map { .array([.string($0.action.id), .number($0.score), .bool($0.exact)]) })
        m.check("matchActions \(describe(q[0])) limit \(limit)", got, q[2])
        let prepared = JSONValue.array(index.match(query, limit: limit).map { .array([.string($0.action.id), .number($0.score), .bool($0.exact)]) })
        m.check("ActionIndex \(describe(q[0]))", prepared, q[2])
        if let title = q[4]?.string { m.check("fuzzyScore \(describe(q[0])) \(title)", .number(fuzzyScore(query, title)), q[3]) }
      }
    }
    #expect(m.total == 0, "\(m.report)")
  }
}

@Suite struct SmallDifferential {
  static let fixture = Result { try Fixture.load("small.json") }

  @Test func quickCreate() throws {
    var m = Mismatches()
    for c in try SmallDifferential.fixture.get()["quick"]!.items {
      let q = c[0]!.str
      m.check("quick \(describe(c[0]))", .array(matchQuickCreate(q).map { .string($0.id) }), c[1])
      m.check("quick 1 \(describe(c[0]))", .array(matchQuickCreate(q, limit: 1).map { .string($0.id) }), c[2])
      m.check("quick 10 \(describe(c[0]))", .array(matchQuickCreate(q, limit: 10).map { .string($0.id) }), c[3])
    }
    #expect(m.total == 0, "\(m.report)")
  }

  @Test func extensionRows() throws {
    let f = try SmallDifferential.fixture.get()["extensions"]!
    let list = f["list"]!.items.map { ExtensionCandidate(id: $0["id"]!.str, title: $0["title"]!.str, icon: $0["icon"]!.optionalString, action: $0["action"]!.bool, options: $0["options"]!.bool) }
    var m = Mismatches()
    let rows = { (r: ExtensionRows) in obj(["rows": .array(r.rows.map(json)), "exact": .bool(r.exact)]) }
    for c in f["cases"]!.items {
      let q = c[0]!.str
      m.check("ext \(q)", rows(extensionSuggestions(q, list)), c[1])
      m.check("ext 1 \(q)", rows(extensionSuggestions(q, list, limit: 1)), c[2])
      m.check("ext none \(q)", rows(extensionSuggestions(q, [])), c[3])
    }
    #expect(m.total == 0, "\(m.report)")
  }

  @Test func recentTabs() throws {
    var m = Mismatches()
    for c in try SmallDifferential.fixture.get()["tabs"]!.items {
      let tabs = c[0]!.items.map { OpenTabRow(id: $0["id"]!.str, url: $0["url"]!.str, title: $0["title"]!.str, favicon: $0["favicon"]!.optionalString, lastActiveAt: $0["lastActiveAt"]!.double) }
      let exclude = c[1]!.optionalString
      let got = c[2]!.isNull ? recentTabSuggestions(tabs, exclude: exclude) : recentTabSuggestions(tabs, exclude: exclude, limit: c[2]!.int)
      m.check("recentTabs \(describe(c[1])) \(describe(c[2]))", .array(got.map(json)), c[3])
    }
    #expect(m.total == 0, "\(m.report)")
  }
}

private func json(_ e: SearchEngine) -> JSONValue {
  obj([
    "id": .string(e.id), "name": .string(e.name), "keyword": .string(e.keyword), "url": .string(e.url), "suggestUrl": e.suggestUrl.map(JSONValue.string),
    "custom": e.custom ? .bool(true) : nil, "extension": e.extension.map { obj(["id": .string($0.id), "name": .string($0.name)]) },
  ])
}

private func json(_ e: ExtensionSearchEngine) -> JSONValue {
  obj([
    "profile": .string(e.profile), "extensionId": .string(e.extensionId), "extensionName": .string(e.extensionName), "name": .string(e.name),
    "keyword": .string(e.keyword), "url": .string(e.url), "suggestUrl": e.suggestUrl.map(JSONValue.string), "isDefault": .bool(e.isDefault),
  ])
}

@Suite struct EngineDifferential {
  @Test func enginesValidationAndChromeLists() throws {
    let f = try Fixture.load("engines.json")
    var m = Mismatches()
    let custom = f["custom"]!.items.map { CustomSearchEngine(id: $0["id"]!.str, name: $0["name"]!.str, keyword: $0["keyword"]!.str, url: $0["url"]!.str) }
    let ext = f["ext"]!.items.map {
      ExtensionSearchEngine(
        profile: $0["profile"]!.str, extensionId: $0["extensionId"]!.str, extensionName: $0["extensionName"]!.str, name: $0["name"]!.str,
        keyword: $0["keyword"]!.str, url: $0["url"]!.str, suggestUrl: $0["suggestUrl"]?.string, isDefault: $0["isDefault"]!.bool
      )
    }
    let all = allEngines(custom: custom, extension: ext)
    m.check("allEngines", .array(all.map(json)), f["all"])
    for (e, c) in zip(all, f["hosts"]!.items) { m.check("engineHost \(e.id)", .string(engineHost(e)), c[1]) }
    m.check("controlling", js(controllingExtensionEngine(ext)?.extensionId), f["controlling"])
    for c in f["byId"]!.items { m.check("engineById \(c[0]!.str)", .string(engineById(all, c[0]!.str).id), c[1]) }
    for c in f["validate"]!.items {
      let input = EngineInput(name: c[0]!["name"]!.str, keyword: c[0]!["keyword"]!.str, url: c[0]!["url"]!.str)
      m.check("validate \(describe(c[0]))", js(validateEngine(input, all)), c[1])
      m.check("validate ignoring c1 \(describe(c[0]))", js(validateEngine(input, all, ignoreId: "c1")), c[2])
      let made = makeCustomEngine(input, id: "id9")
      m.check("make \(describe(c[0]))", obj(["id": .string(made.id), "name": .string(made.name), "keyword": .string(made.keyword), "url": .string(made.url)]), c[3])
    }
    for c in f["chrome"]!.items {
      let list = try JSONValue(parsing: c[0]!.str)
      m.check("chrome \(c[0]!.str.prefix(60))", .array(extensionEnginesFromChrome(profile: "prof", list: list).map(json)), c[1])
    }
    for c in f["parsed"]!.items { m.check("parseSuggestions \(c[0]!.str)", .array(parseSuggestions(try JSONValue(parsing: c[0]!.str)).map(JSONValue.string)), c[1]) }
    for c in f["requests"]!.items {
      let e = engineById(builtInEngines, c[0]!.str)
      m.check("suggestRequestUrl \(e.id) \(describe(c[1]))", js(suggestRequestUrl(e, c[1]!.str)), c[2])
      m.check("searchUrl \(e.id) \(describe(c[1]))", .string(searchUrl(e, c[1]!.str)), c[3])
    }
    #expect(m.total == 0, "\(m.report)")
  }
}

@Suite struct SiteSearchDifferential {
  @Test func scopesOffersKeysAndUrls() throws {
    let f = try Fixture.load("siteSearch.json")
    var m = Mismatches()
    let engines = allEngines(custom: [CustomSearchEngine(id: "c1", name: "My Wiki", keyword: "wk", url: "https://wiki.example/?q=%s")])
    let sources = ScopeSources(engines: engines, hosts: f["hosts"]!.items.map(\.str))
    let builtIns = ScopeSources(engines: builtInEngines)
    for c in f["scopes"]!.items {
      m.check("findScope \(describe(c[0]))", json(findScope(c[0]!.str, sources)), c[1])
      m.check("findScope built-ins \(describe(c[0]))", json(findScope(c[0]!.str, builtIns)), c[2])
    }
    for c in f["offered"]!.items { m.check("offered \(describe(c[0])) \(describe(c[1]))", json(offeredSiteSearch(c[0]!.str, c[1]!.str, sources)), c[2]) }
    for c in f["spaces"]!.items {
      let got = keywordBySpace(c[0]!.str, c[1]!.str).map { obj(["keyword": .string($0.keyword), "from": .string($0.from)]) } ?? .null
      m.check("keywordBySpace \(describe(c[0])) \(describe(c[1]))", got, c[2])
    }
    for c in f["keys"]!.items {
      let mods = c[1]!
      let s = c[2]!
      let state = SiteSearchKeyState(typed: s["typed"]!.str, completion: s["completion"]!.str, scope: scope(s["scope"]!), offered: scope(s["offered"]!), scopeFrom: s["scopeFrom"]!.str)
      let got = siteSearchKey(c[0]!.str, SiteSearchKeyModifiers(shiftKey: mods["shiftKey"]!.bool, altKey: mods["altKey"]!.bool, metaKey: mods["metaKey"]!.bool, ctrlKey: mods["ctrlKey"]!.bool), state)
      let encoded: JSONValue
      switch got {
      case .enter(let scope, let from)?: encoded = obj(["kind": .string("enter"), "scope": json(scope), "from": .string(from)])
      case .leave(let text)?: encoded = obj(["kind": .string("leave"), "text": .string(text)])
      case .accept(let text)?: encoded = obj(["kind": .string("accept"), "text": .string(text)])
      case nil: encoded = .null
      }
      m.check("siteSearchKey \(describe(c[0])) \(describe(c[2]))", encoded, c[3])
    }
    for c in f["scoped"]!.items { m.check("scopedSearchUrl \(describe(c[0]))", .string(scopedSearchUrl(scope(c[0]!)!, c[1]!.str, builtInEngines[0])), c[2]) }
    #expect(m.total == 0, "\(m.report)")
  }
}

private func json(_ f: TextFragment?) -> JSONValue {
  guard let f else { return .null }
  return obj(["prefix": f.prefix.map(JSONValue.string), "start": .string(f.start), "end": f.end.map(JSONValue.string), "suffix": f.suffix.map(JSONValue.string)])
}

private func fragment(_ v: JSONValue) -> TextFragment {
  TextFragment(prefix: v["prefix"]?.string, start: v["start"]!.str, end: v["end"]?.string, suffix: v["suffix"]?.string)
}

@Suite struct TextFragmentDifferential {
  @Test func chooseAndApply() throws {
    let f = try Fixture.load("textFragment.json")
    var m = Mismatches()
    for c in f["cases"]!.items {
      let ctx = c[0]!
      let context = SelectionContext(selected: ctx["selected"]!.str, before: ctx["before"]!.str, after: ctx["after"]!.str, pageText: ctx["pageText"]!.str)
      let chosen = chooseTextFragment(context)
      m.check("choose \(describe(ctx["selected"]))", json(chosen), c[1])
      if let chosen { m.check("apply \(describe(c[3]))", .string(withTextFragment(c[3]!.str, chosen)), c[2]) }
    }
    for c in f["direct"]!.items { m.check("direct \(describe(c[0]))", .string(withTextFragment(c[1]!.str, fragment(c[0]!))), c[2]) }
    #expect(m.total == 0, "\(m.report)")
  }
}

@Suite struct SuggestDifferential {
  static let fixture = Result { try Fixture.load("suggest.json") }

  @Test func keystrokeSequencesMatchPackagesCore() throws {
    let f = try SuggestDifferential.fixture.get()
    let actions = ActionIndex(f["actions"]!.items.map { CommandAction(id: $0["id"]!.str, title: $0["title"]!.str, keywords: $0["keywords"]?.items.map(\.str), icon: $0["icon"]?.string, hint: $0["hint"]?.string) })
    let testBangs = bangTable(f["bangs"]!.str)
    var m = Mismatches()
    var steps = 0
    for run in f["runs"]!.items {
      let o = run["options"]!
      let rows = run["rows"]!.items
      var options = SuggestOptions(
        limit: o["limit"]!.int, now: o["now"]!.double, engine: engineById(builtInEngines, o["engine"]!.str),
        preference: SearchPreference(rawValue: o["preference"]!.str)!, actions: actions,
        extensions: o["extensions"]!.items.map { ExtensionCandidate(id: $0["id"]!.str, title: $0["title"]!.str, icon: $0["icon"]!.optionalString, action: $0["action"]!.bool, options: $0["options"]!.bool) },
        currentTabId: o["currentTabId"]?.string, currentUrl: o["currentUrl"]?.string, scope: scope(o["scope"]!), preventInline: o["preventInline"]!.bool,
        bangs: o["bangs"]!.isNull ? nil : testBangs
      )
      var history: [HistoryRow] = []
      var bookmarks: [BookmarkRow] = []
      var tabs: [TabRow] = []
      var index: SuggestionIndex?
      for (i, step) in run["steps"]!.items.enumerated() {
        var rebuild = index == nil
        if let ids = step["history"] {
          history = ids.items.map { let r = rows[$0.int]; return HistoryRow(url: r["url"]!.str, title: r["title"]!.str, favicon: r["favicon"]!.optionalString, visits: r["visits"]!.double, lastVisit: r["lastVisit"]!.double) }
          rebuild = true
        }
        if let ids = step["bookmarks"] {
          bookmarks = ids.items.map { let r = rows[$0.int]; return BookmarkRow(url: r["url"]!.str, title: r["title"]!.str, favicon: r["favicon"]!.optionalString) }
          rebuild = true
        }
        if let ids = step["tabs"] {
          tabs = ids.items.map { let r = rows[$0.int]; return TabRow(id: r["id"]!.str, url: r["url"]!.str, title: r["title"]!.str, favicon: r["favicon"]!.optionalString) }
        }
        if rebuild { index = SuggestionIndex(history: history, bookmarks: bookmarks, reusing: index) }
        if step["prepare"] != nil { index!.prepare(deadline: .now + .milliseconds(1)) }
        options.remote = step["remote"]?.items.map(\.str) ?? []
        let got = index!.suggest(step["q"]!.str, tabs: tabs, options: options)
        steps += 1
        m.check("seed \(run["seed"]!.int) step \(i) \(describe(step["q"]))", json(got), step["expect"])
      }
    }
    #expect(steps > 2000)
    #expect(m.total == 0, "\(m.report)")
  }

  @Test func nowOfZeroNaNOrInfinity() throws {
    var m = Mismatches()
    for c in try SuggestDifferential.fixture.get()["edge"]!.items {
      let s = c[0]!
      let source = SuggestionSource(
        tabs: s["tabs"]!.items.map { TabRow(id: $0["id"]!.str, url: $0["url"]!.str, title: $0["title"]!.str, favicon: $0["favicon"]!.optionalString) },
        history: s["history"]!.items.map { HistoryRow(url: $0["url"]!.str, title: $0["title"]!.str, favicon: $0["favicon"]!.optionalString, visits: $0["visits"]!.double, lastVisit: $0["lastVisit"]!.double) }
      )
      let options = SuggestOptions(now: c[1]!.double, preference: SearchPreference(rawValue: c[2]!.str)!)
      m.check("now \(describe(c[1]))", json(buildSuggestions(c[3]!.str, source, options)), c[4])
    }
    #expect(m.total == 0, "\(m.report)")
  }
}
