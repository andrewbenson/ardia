import SolaraModel

let titleSeparators = [" / ", " | ", " - ", " — ", " – ", " · ", " • ", " :: "]

func squash(_ s: String) -> String {
  String(s.lowercased().unicodeScalars.filter { ($0 >= "a" && $0 <= "z") || ($0 >= "0" && $0 <= "9") }.map(Character.init))
}

func isIpAddress(_ host: String) -> Bool {
  if host.hasPrefix("[") { return true }
  let parts = host.split(separator: ".", omittingEmptySubsequences: false)
  guard parts.count == 4 else { return false }
  return parts.allSatisfy { p in (1...3).contains(p.count) && p.allSatisfy { $0 >= "0" && $0 <= "9" } }
}

func hostLabel(_ host: String) -> String {
  if isIpAddress(host) { return host }
  let parts = host.split(separator: ".", omittingEmptySubsequences: true).map(String.init)
  if parts.count < 2 { return parts.first ?? "" }
  let second = parts[parts.count - 2]
  return parts.count > 2 && second.jsLength <= 3 && parts[parts.count - 1].jsLength <= 2 ? parts[parts.count - 3] : second
}

func tidyHost(_ host: String) -> String {
  let label = hostLabel(host)
  guard let first = label.utf16.first else { return "" }
  if (0xD800...0xDBFF).contains(first) { return label }
  return String(utf16Units: [first]).uppercased() + label.jsSlice(1)
}

func titleEnds(_ title: String) -> [(String, String)] {
  var out: [(String, String)] = []
  for sep in titleSeparators {
    let last = title.jsLastIndexOf(sep)
    if last > 0 { out.append((title.jsSlice(last + sep.jsLength).jsTrim(), title.jsSlice(0, last).jsTrim())) }
    let first = title.jsIndexOf(sep)
    if first > 0 { out.append((title.jsSlice(0, first).jsTrim(), title.jsSlice(first + sep.jsLength).jsTrim())) }
  }
  return out.filter { !$0.0.isEmpty && !$0.1.isEmpty }
}

func siteFromTitles(_ host: String, _ titles: [String]) -> String? {
  let label = squash(hostLabel(host))
  func looksLikeHost(_ site: String) -> Bool {
    let s = squash(site)
    return !s.isEmpty && !label.isEmpty && (s == label || (s.count >= 3 && (label.contains(s) || s.contains(label))))
  }
  for (site, _) in titleEnds(titles[0]) {
    if site.split(separator: " ", omittingEmptySubsequences: false).count <= 3 && looksLikeHost(site)
      && titles.allSatisfy({ t in titleEnds(t).contains { $0.0 == site } })
    {
      return site
    }
  }
  if titles.count < 2 { return nil }
  for (site, _) in titleEnds(titles[0]) where titles.allSatisfy({ t in titleEnds(t).contains { $0.0 == site } }) { return site }
  return nil
}

func pageOf(_ title: String, _ site: String?) -> String {
  guard let site else { return title.jsTrim() }
  return titleEnds(title).first { $0.0 == site }?.1 ?? title.jsTrim()
}

extension Session {
  func siteKey(_ url: String) -> String { hostLabel(hostOf(url)).lowercased() }

  func siteName(_ members: [(url: String, title: String)]) -> String {
    let host = members.map { hostOf($0.url) }.first { !$0.isEmpty } ?? ""
    let titles = members.compactMap { m in !m.title.isEmpty && m.title != m.url ? m.title : nil }
    let label = squash(hostLabel(host))
    let titledLikeHost = label.isEmpty ? nil : titles.first { squash($0) == label }?.jsTrim()
    return (titles.isEmpty ? nil : siteFromTitles(host, titles)) ?? titledLikeHost ?? tidyHost(host)
  }

  func autoGroupName(_ members: [(url: String, title: String)]) -> String {
    if members.isEmpty { return "" }
    let hosts = members.map { hostOf($0.url) }
    var titledByHost = OrderedDict<String, [String]>()
    var loadedByUrl: [String: (url: String, title: String)] = [:]
    for (i, m) in members.enumerated() {
      if m.title.isEmpty || m.title == m.url { continue }
      titledByHost[hosts[i], default: []].append(m.title)
      if loadedByUrl[m.url] == nil { loadedByUrl[m.url] = m }
    }
    var siteOfHost: [String: String] = [:]
    for host in OrderedSet(hosts) {
      let titles = titledByHost[host]
      let site = titles.flatMap { siteFromTitles(host, $0) }
      siteOfHost[host] = site ?? tidyHost(host)
    }
    let sites = hosts.map { siteOfHost[$0] ?? "" }
    let site = sites[0]
    if site.isEmpty || sites.contains(where: { $0 != site }) { return site.isEmpty ? members[0].title : site }
    let siteInTitles = members.contains { m in !m.title.isEmpty && pageOf(m.title, site) != m.title.jsTrim() } ? site : nil
    let pages = members.map { m -> String? in
      let loaded = !m.title.isEmpty && m.title != m.url ? m : loadedByUrl[m.url]
      return loaded.map { pageOf($0.title, siteInTitles) }
    }
    guard let siteInTitles, let page = pages[0], !page.isEmpty, !pages.contains(where: { $0 != page }), squash(page) != squash(site) else {
      return site
    }
    return "\(siteInTitles) \(page)"
  }
}
