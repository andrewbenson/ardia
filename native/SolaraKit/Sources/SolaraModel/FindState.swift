public struct FindState: JSONConvertible {
  public var json: JSONObject

  public init() {
    json = ["open": false, "query": "", "count": .null, "active": 0]
  }

  public init(json: JSONObject) {
    self.json = json
  }
}
