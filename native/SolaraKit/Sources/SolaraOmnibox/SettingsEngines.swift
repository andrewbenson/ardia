import Foundation
import SolaraModel

private func text(_ value: SolaraModel.JSONValue?) -> String { value?.string ?? "" }

public func customSearchEngines(_ settings: Settings) -> [CustomSearchEngine] {
  (settings["customSearchEngines"]?.array ?? []).compactMap { e in
    guard e.object != nil else { return nil }
    return CustomSearchEngine(id: text(e["id"]), name: text(e["name"]), keyword: text(e["keyword"]), url: text(e["url"]))
  }
}

public func extensionSearchEngines(_ settings: Settings) -> [ExtensionSearchEngine] {
  (settings["extensionSearchEngines"]?.array ?? []).compactMap { e in
    guard e.object != nil else { return nil }
    return ExtensionSearchEngine(
      profile: text(e["profile"]), extensionId: text(e["extensionId"]), extensionName: text(e["extensionName"]), name: text(e["name"]),
      keyword: text(e["keyword"]), url: text(e["url"]), suggestUrl: e["suggestUrl"]?.string, isDefault: e["isDefault"]?.truthy ?? false
    )
  }
}

public func searchEngines(_ settings: Settings) -> [SearchEngine] {
  var engines = allEngines(custom: customSearchEngines(settings), extension: extensionSearchEngines(settings))
  if let legacy = settings.string("customSearchUrl"), legacy.units.contains(Units("%s")) {
    let at = engines.firstIndex { $0.extension != nil } ?? engines.count
    engines.insert(SearchEngine(id: "custom", name: "Custom", keyword: "custom", url: legacy, custom: true), at: at)
  }
  return engines
}

public func controllingSearchExtension(_ settings: Settings) -> ExtensionSearchEngine? {
  controllingExtensionEngine(extensionSearchEngines(settings))
}

public func defaultSearchEngine(_ settings: Settings) -> SearchEngine {
  let controlling = controllingSearchExtension(settings)
  return engineById(searchEngines(settings), controlling.map { extensionEngineId($0.extensionId) } ?? settings.string("searchEngine"))
}

public func searchUrlPrefix(_ settings: Settings) -> String { defaultSearchEngine(settings).url }

public func validateCustomEngine(_ settings: Settings, _ input: EngineInput, ignoreId: String? = nil) -> String? {
  validateEngine(input, searchEngines(settings), ignoreId: ignoreId)
}
