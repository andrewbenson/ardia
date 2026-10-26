import Foundation

private let globalParams: Set<Units> = Set([
  "gclid", "gclsrc", "dclid", "gbraid", "wbraid", "gad_source", "gad_campaignid", "_ga", "_gl", "srsltid",
  "fbclid", "igshid", "msclkid", "twclid", "ttclid", "li_fat_id", "yclid", "ysclid", "rdt_cid", "epik",
  "mc_cid", "mc_eid", "_hsenc", "_hsmi", "__hssc", "__hstc", "__hsfp", "hsctatracking", "mkt_tok", "elqtrackid",
  "elqtrack", "vero_id", "vero_conv", "_kx", "__s",
  "oly_anon_id", "oly_enc_id", "_openstat", "wickedid", "rb_clickid", "s_cid", "irclickid", "cjevent", "sscid",
  "zanpid", "ranmid", "raneaid", "ransiteid", "trk_contact", "trk_msg", "trk_module", "trk_sid",
].map(Units.init))

private let globalPrefixes = ["utm_", "pk_", "mtm_", "piwik_", "matomo_", "hsa_", "stm_"].map(Units.init)

private struct SiteParams {
  let hosts: [Units]
  let params: [Units]
  let prefixes: [Units]

  init(hosts: [String], params: [String], prefixes: [String] = []) {
    self.hosts = hosts.map(Units.init)
    self.params = params.map(Units.init)
    self.prefixes = prefixes.map(Units.init)
  }
}

private let siteParams: [SiteParams] = [
  SiteParams(hosts: ["youtube.com", "youtu.be", "music.youtube.com"], params: ["si", "pp", "feature"]),
  SiteParams(hosts: ["open.spotify.com"], params: ["si", "nd", "context"]),
  SiteParams(hosts: ["instagram.com"], params: ["igsh", "img_index"]),
  SiteParams(hosts: ["x.com", "twitter.com"], params: ["s", "t", "ref_src", "ref_url"]),
  SiteParams(hosts: ["threads.net", "threads.com"], params: ["xmt", "slof"]),
  SiteParams(hosts: ["tiktok.com"], params: ["is_from_webapp", "sender_device", "sender_web_id", "_r", "_t"]),
  SiteParams(hosts: ["linkedin.com"], params: ["trk", "trackingid", "lipi", "midtoken", "midsig", "trkemail", "eid"]),
  SiteParams(hosts: ["reddit.com"], params: ["share_id", "ref_source", "ref_campaign"]),
  SiteParams(hosts: ["medium.com"], params: ["source"]),
  SiteParams(hosts: ["facebook.com"], params: ["mibextid", "sfnsn", "rdid", "share_url"]),
  SiteParams(
    hosts: ["amazon.com", "amazon.co.uk", "amazon.de", "amazon.fr", "amazon.it", "amazon.es", "amazon.ca", "amazon.co.jp", "amazon.in", "amazon.com.au"],
    params: ["_encoding", "psc", "ref", "ref_", "tag", "linkcode", "linkid", "camp", "creative", "creativeasin", "content-id", "crid", "sprefix", "qid", "sr", "dib", "dib_tag"],
    prefixes: ["pd_rd_", "pf_rd_"]
  ),
]

private func siteRules(_ hostname: Units) -> [SiteParams] {
  var host = JS.lower(hostname)
  if host.hasPrefix(Units("www.")) { host.removeFirst(4) }
  return siteParams.filter { rule in rule.hosts.contains { host == $0 || host.hasSuffix([Unit.dot] + $0) } }
}

private func decodeName(_ raw: Units) -> Units {
  let spaced = raw.map { $0 == Unit.plus ? Unit.space : $0 }
  if let decoded = JS.decodeURIComponent(spaced.string) { return JS.lower(decoded.units) }
  return JS.lower(raw)
}

private func isTrackingParam(_ name: Units, _ hostname: Units) -> Bool {
  let key = JS.lower(name)
  if globalParams.contains(key) || globalPrefixes.contains(where: key.hasPrefix) { return true }
  return siteRules(hostname).contains { $0.params.contains(key) || $0.prefixes.contains(where: key.hasPrefix) }
}

public func cleanUrl(_ url: String) -> String {
  let u = url.units
  let queryStart = u.firstIndex { $0 == Unit.question || $0 == Unit.hash }
  guard let queryStart, u[queryStart] == Unit.question else { return url }
  let hashStart = u[queryStart...].firstIndex(of: Unit.hash) ?? u.count
  if hashStart < u.count && u[hashStart...].contains(where: Unit.isLineTerminator) { return url }
  guard let hostname = WhatwgUrl.httpHostname(u) else { return url }
  let base = Array(u[..<queryStart])
  let query = Array(u[queryStart..<hashStart])
  let hash = Array(u[hashStart...])
  let pairs = query.dropFirst().split(separator: UInt16(0x26), omittingEmptySubsequences: false).map(Array.init)
  let kept = pairs.filter { pair in
    guard !pair.isEmpty else { return false }
    let name = pair.split(separator: UInt16(0x3d), maxSplits: 1, omittingEmptySubsequences: false).first.map(Array.init) ?? []
    return !isTrackingParam(decodeName(name), hostname)
  }
  if kept.count == pairs.count { return url }
  let joined = kept.isEmpty ? Units() : [Unit.question] + Array(kept.joined(separator: [UInt16(0x26)]))
  return (base + joined + hash).string
}

public func markdownLink(title: String, url: String) -> String {
  let text = (title.isEmpty ? url : title).units
  var escaped = Units()
  for c in text {
    if c == Unit.openBracket || c == Unit.closeBracket { escaped.append(Unit.backslash) }
    escaped.append(c)
  }
  return "[" + escaped.string + "](" + cleanUrl(url) + ")"
}
