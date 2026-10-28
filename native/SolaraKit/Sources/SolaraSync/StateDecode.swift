import SolaraModel

public func isJSObject(_ value: JSONValue?) -> Bool {
  if case .object = value { return true }
  return false
}

func isNumber(_ value: JSONValue?) -> Bool { value?.number != nil }
func isString(_ value: JSONValue?) -> Bool { value?.string != nil }

public func readableRecord(_ r: JSONValue?) -> Bool {
  guard isJSObject(r), isString(r?["h"]), let o = r?["o"]?.array else { return false }
  return isString(o.first) && o.count > 1 && isNumber(o[1])
}

public func readableOp(_ op: JSONValue?) -> Bool { isJSObject(op) && isString(op?["k"]) && isString(op?["h"]) }

public func readableBatch(_ f: JSONValue?) -> Bool {
  guard isJSObject(f), isString(f?["device"]), isNumber(f?["seq"]), let ops = f?["ops"]?.array else { return false }
  return ops.allSatisfy(readableOp)
}

public func readableRebuild(_ r: JSONValue?) -> Bool {
  guard let r, isJSObject(r) else { return false }
  if let settled = r.object?["settled"] {
    guard let list = settled.array, list.allSatisfy(isString) else { return false }
  }
  if let noted = r.object?["noted"] {
    guard let byPrefix = noted.object else { return false }
    for (_, digests) in byPrefix {
      guard let digests = digests.object, digests.allSatisfy({ isString($0.value) }) else { return false }
    }
  }
  return true
}

public func readableScope(_ v: JSONValue?) -> Bool {
  guard let v, let object = v.object else { return false }
  let maps = ["records", "base", "vv", "extra", "files", "damaged", "seen"].map { object[$0] }
  guard maps.allSatisfy(isJSObject) else { return false }
  guard object["records"]!.object!.allSatisfy({ readableRecord($0.value) }) else { return false }
  guard object["base"]!.object!.allSatisfy({ isString($0.value) }) else { return false }
  for name in ["vv", "seen", "damaged"] where !object[name]!.object!.allSatisfy({ isNumber($0.value) }) { return false }
  guard object["extra"]!.object!.allSatisfy({ $0.value.array?.allSatisfy(isNumber) ?? false }) else { return false }
  guard object["files"]!.object!.allSatisfy({ isJSObject($0.value) }) else { return false }
  guard let unapplied = object["unapplied"]?.array, unapplied.allSatisfy(isString) else { return false }
  guard let outbox = object["outbox"]?.array, outbox.allSatisfy(readableOp) else { return false }
  guard isNumber(object["seq"]) else { return false }
  if let journal = object["journal"] {
    guard let list = journal.array, list.allSatisfy(readableBatch) else { return false }
  }
  if let held = object["heldOutbox"] {
    guard let list = held.array, list.allSatisfy(readableOp) else { return false }
  }
  if let rebuild = object["rebuild"], !readableRebuild(rebuild) { return false }
  return true
}

public func syncDocIsNewer(_ saved: JSONValue) -> Bool {
  guard let object = saved.object else { return false }
  return object["v"] != .number(1)
}
