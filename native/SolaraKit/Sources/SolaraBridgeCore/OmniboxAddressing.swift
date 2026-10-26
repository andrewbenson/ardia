import SolaraModel
import SolaraOmnibox
import SolaraStore

public struct OmniboxAddressing: WebAddressing {
  public init() {}

  public func resolveInput(_ input: String, searchUrlPrefix: String) -> String {
    SolaraOmnibox.resolveInput(input, search: searchUrlPrefix)
  }

  public func searchUrlPrefix(_ settings: Settings) -> String {
    SolaraOmnibox.searchUrlPrefix(settings)
  }

  public func parseURL(_ url: String) -> ParsedURL? {
    guard let parsed = WhatwgURL(url) else { return nil }
    return ParsedURL(protocol: parsed.protocol, host: parsed.host, hostname: parsed.hostname)
  }
}
