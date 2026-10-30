enum LiveRetiredSource: String, CaseIterable, Sendable {
  case bitbucket, confluence, jira

  var configKeys: [String] {
    switch self {
    case .bitbucket: ["bitbucketUser"]
    case .confluence: ["confluenceSite", "confluenceEmail"]
    case .jira: []
    }
  }

  static let configKeys = allCases.flatMap(\.configKeys)

  static func source(_ value: LiveAnyJSON?) -> Self? {
    guard case .string(let name) = value else { return nil }
    return Self(rawValue: name)
  }
}

extension LiveState {
  mutating func scrubRetiredSources() {
    guard var raw = originalKnown else { return }
    var removedFolders = Set<String>()
    if case .object(var values) = raw["folders"] {
      for (id, value) in values {
        guard case .object(var folder) = value, case .array(let sources) = folder["sources"] else { continue }
        let retired = Set(sources.compactMap(LiveRetiredSource.source))
        if retired.isEmpty { continue }
        retiredSources.formUnion(retired)
        let remaining = sources.filter { LiveRetiredSource.source($0) == nil }
        if remaining.isEmpty {
          removedFolders.insert(id)
          values[id] = nil
        } else {
          folder["sources"] = .array(remaining)
          values[id] = .object(folder)
        }
      }
      raw["folders"] = .object(values)
    }
    for id in removedFolders { removeFolder(id) }
    if case .array(let order) = raw["folderOrder"] {
      raw["folderOrder"] = .array(order.filter { value in
        guard case .string(let id) = value else { return true }
        return !removedFolders.contains(id)
      })
    }
    for key in ["items", "known", "unread", "hidden", "completed", "completing", "status"] {
      guard case .object(var values) = raw[key] else { continue }
      for id in removedFolders { values[id] = nil }
      if ["items", "hidden", "completed"].contains(key) {
        for (id, value) in values {
          guard case .array(let entries) = value else { continue }
          values[id] = .array(entries.filter { entry in
            guard case .object(let fields) = entry else { return true }
            let item: [String: LiveAnyJSON]
            if key == "completed" {
              guard case .object(let nested) = fields["item"] else { return true }
              item = nested
            } else {
              item = fields
            }
            guard let source = LiveRetiredSource.source(item["source"]) else { return true }
            retiredSources.insert(source)
            return false
          })
        }
      }
      raw[key] = .object(values)
    }
    if case .object(var values) = raw["accounts"] {
      for source in LiveRetiredSource.allCases where values.removeValue(forKey: source.rawValue) != nil {
        retiredSources.insert(source)
        retiredCredentials.insert(source)
      }
      raw["accounts"] = .object(values)
    }
    if case .object(var values) = raw["config"] {
      for source in LiveRetiredSource.allCases {
        for key in source.configKeys where values.removeValue(forKey: key) != nil {
          retiredSources.insert(source)
          retiredCredentials.insert(source)
        }
      }
      raw["config"] = .object(values)
    }
    originalKnown = raw
  }
}
