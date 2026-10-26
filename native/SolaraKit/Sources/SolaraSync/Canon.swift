import SolaraModel

public func syncCanonical(_ value: JSONValue) -> String {
  sortedKeys(value).text()
}

func sortedKeys(_ value: JSONValue) -> JSONValue {
  switch value {
  case .array(let items): return .array(items.map(sortedKeys))
  case .object(let object):
    var out = JSONObject()
    for key in object.keys.sorted(by: jsKeyPrecedes) { out[key] = sortedKeys(object[key]!) }
    return .object(out)
  default: return value
  }
}
