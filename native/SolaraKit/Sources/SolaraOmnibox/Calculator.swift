import Foundation

private let space = "[\\t\\n\\u000b\\f\\r \\u00a0\\u1680\\u2000-\\u200a\\u2028\\u2029\\u202f\\u205f\\u3000\\ufeff]"
private let piTau = "πΠϖτΤ"

private func caseless(_ word: String) -> String {
  word.map { c in
    guard c.isASCII, c.isLetter else { return String(c) }
    return "[\(c.lowercased())\(c.uppercased())]"
  }.joined()
}

private enum Token {
  case number(Double)
  case op(String)
  case id(String)
}

private let constants: [String: Double] = ["pi": .pi, "π": .pi, "e": M_E, "tau": 2 * .pi, "τ": 2 * .pi, "constructor": .nan]

private let functions: [String: @Sendable ([Double]) -> Double] = [
  "sqrt": { sqrt($0[0]) },
  "cbrt": { cbrt($0[0]) },
  "abs": { abs($0[0]) },
  "sin": { sin($0[0]) },
  "cos": { cos($0[0]) },
  "tan": { tan($0[0]) },
  "asin": { asin($0[0]) },
  "acos": { acos($0[0]) },
  "atan": { atan($0[0]) },
  "sinh": { sinh($0[0]) },
  "cosh": { cosh($0[0]) },
  "tanh": { tanh($0[0]) },
  "ln": { log($0[0]) },
  "log": { $0.count < 2 ? log10($0[0]) : log($0[0]) / log($0[1]) },
  "log2": { FdLibm.log2($0[0]) },
  "log10": { log10($0[0]) },
  "exp": { exp($0[0]) },
  "floor": { floor($0[0]) },
  "ceil": { ceil($0[0]) },
  "round": { JS.round($0[0]) },
  "min": { JS.min($0) },
  "max": { JS.max($0) },
  "pow": { JS.pow($0[0], $0.count > 1 ? $0[1] : .nan) },
]

private let functionNames = ["sqrt", "cbrt", "abs", "sin", "cos", "tan", "asin", "acos", "atan", "sinh", "cosh", "tanh", "ln", "log", "log2", "log10", "exp", "floor", "ceil", "round", "min", "max", "pow"]

private let operatorAliases: [String: String] = ["×": "*", "·": "*", "÷": "/", "−": "-", "–": "-", "**": "^"]
private let operatorUnits: [UInt16: String] = {
  var map: [UInt16: String] = [:]
  for op in ["-", "+", "*", "/", "^", "%", "!", "(", ")", ",", "×", "·", "÷", "−", "–", "°"] { map[op.utf16.first!] = op }
  return map
}()

private let numberToken = Pattern("^([0-9]+(?:\\.[0-9]*)?|\\.[0-9]+)(?:[eE][+-]?[0-9]+)?")
private let identifierToken = Pattern("^([a-zA-Z][a-zA-Z0-9]*|[πΠϖ]|[τΤ])")

private func tokenize(_ source: Units) -> [Token]? {
  var tokens: [Token] = []
  var i = 0
  while i < source.count {
    let c = source[i]
    if JS.isSpace(c) {
      while i < source.count && JS.isSpace(source[i]) { i += 1 }
      continue
    }
    let rest = Array(source[i...])
    if let num = numberToken.firstMatch(rest) {
      tokens.append(.number(JS.number(num[0]!.string)))
      i += num.end
      continue
    }
    if c == 0x2a && i + 1 < source.count && source[i + 1] == 0x2a {
      tokens.append(.op("^"))
      i += 2
      continue
    }
    if let op = operatorUnits[c] {
      tokens.append(.op(operatorAliases[op] ?? op))
      i += 1
      continue
    }
    if let id = identifierToken.firstMatch(rest) {
      tokens.append(.id(JS.lower(id[0]!.string)))
      i += id.end
      continue
    }
    return nil
  }
  return tokens
}

private struct ParseError: Error {}

private struct Parser {
  var i = 0
  let tokens: [Token]

  mutating func parse() throws -> Double? {
    let value = try expr()
    return i == tokens.count ? value : nil
  }

  func peek(_ offset: Int = 0) -> Token? {
    i + offset < tokens.count ? tokens[i + offset] : nil
  }

  func isOp(_ value: String, _ offset: Int = 0) -> Bool {
    if case .op(let v) = peek(offset) { return v == value }
    return false
  }

  func isId(_ value: String, _ offset: Int = 0) -> Bool {
    if case .id(let v) = peek(offset) { return v == value }
    return false
  }

  func startsPrimary(_ offset: Int = 0) -> Bool {
    switch peek(offset) {
    case .number: true
    case .id(let v): constants[v] != nil || functions[v] != nil
    case .op(let v): v == "("
    case nil: false
    }
  }

  mutating func expr() throws -> Double {
    var value = try term()
    while isOp("+") || isOp("-") {
      let plus = isOp("+")
      i += 1
      let rhs = try term()
      value = plus ? value + rhs : value - rhs
    }
    return value
  }

  mutating func term() throws -> Double {
    var value = try unary()
    while true {
      if isOp("*") || isOp("/") || isId("mod") || isId("of") || isId("x") {
        let divide = isOp("/")
        let mod = isId("mod")
        i += 1
        let rhs = try unary()
        if divide {
          value /= rhs
        } else if mod {
          value = value.truncatingRemainder(dividingBy: rhs)
        } else {
          value *= rhs
        }
      } else if isOp("%") && startsPrimary(1) {
        i += 1
        value = value.truncatingRemainder(dividingBy: try unary())
      } else if !isNumber(peek()) && startsPrimary() {
        value *= try unary()
      } else {
        return value
      }
    }
  }

  func isNumber(_ token: Token?) -> Bool {
    if case .number = token { return true }
    return false
  }

  mutating func unary() throws -> Double {
    if isOp("-") {
      i += 1
      return -(try unary())
    }
    if isOp("+") {
      i += 1
      return try unary()
    }
    return try power()
  }

  mutating func power() throws -> Double {
    let base = try postfix()
    if isOp("^") {
      i += 1
      return JS.pow(base, try unary())
    }
    return base
  }

  mutating func postfix() throws -> Double {
    var value = try primary()
    while true {
      if isOp("!") {
        i += 1
        value = factorial(value)
      } else if isOp("%") && !startsPrimary(1) {
        i += 1
        value /= 100
      } else if isOp("°") || isId("deg") || isId("degrees") {
        i += 1
        value *= Double.pi / 180
      } else {
        return value
      }
    }
  }

  mutating func primary() throws -> Double {
    guard let t = peek() else { throw ParseError() }
    i += 1
    switch t {
    case .number(let v):
      return v
    case .op(let v) where v == "(":
      let value = try expr()
      try expect(")")
      return value
    case .id(let v):
      if let c = constants[v] { return c }
      if let f = functions[v] {
        try expect("(")
        var args = [try expr()]
        while isOp(",") {
          i += 1
          args.append(try expr())
        }
        try expect(")")
        return f(args)
      }
      throw ParseError()
    default:
      throw ParseError()
    }
  }

  mutating func expect(_ op: String) throws {
    guard isOp(op) else { throw ParseError() }
    i += 1
  }
}

private func factorial(_ n: Double) -> Double {
  if !JS.isInteger(n) || n < 0 || n > 170 { return .nan }
  var out = 1.0
  var k = 2.0
  while k <= n {
    out *= k
    k += 1
  }
  return out
}

private let functionCall = Pattern("[a-zA-Z]\(space)*\\(")

private func removeThousandsSeparators(_ s: Units) -> Units {
  var out = Units()
  out.reserveCapacity(s.count)
  var i = 0
  let n = s.count
  while i < n {
    if Unit.isDigit(s[i]), i + 4 < n, s[i + 1] == Unit.comma, Unit.isDigit(s[i + 2]), Unit.isDigit(s[i + 3]), Unit.isDigit(s[i + 4]),
      i + 5 >= n || !Unit.isDigit(s[i + 5])
    {
      out.append(s[i])
      i += 2
    } else {
      out.append(s[i])
      i += 1
    }
  }
  return out
}

func evaluate(_ expression: Units) -> Double? {
  let source = functionCall.test(expression) ? expression : removeThousandsSeparators(expression)
  guard let tokens = tokenize(source), !tokens.isEmpty else { return nil }
  var parser = Parser(tokens: tokens)
  guard let value = try? parser.parse(), value.isFinite else { return nil }
  return value
}

public func evaluate(_ expression: String) -> Double? { evaluate(expression.units) }

private func formatNumber(_ value: Double, _ digits: Int = 12) -> String {
  if value == 0 { return "0" }
  let rounded = JS.number(JS.toPrecision(value, digits))
  let magnitude = abs(rounded)
  if magnitude >= 1e21 || magnitude < 1e-9 {
    var text = JS.toExponential(rounded).units
    if let e = text.firstIndex(of: 0x65) {
      var zeros = e
      while zeros > 0 && text[zeros - 1] == Unit.zero { zeros -= 1 }
      if zeros < e {
        var start = zeros
        if start > 0 && text[start - 1] == Unit.dot { start -= 1 }
        text.removeSubrange(start..<e)
      }
    }
    return text.string
  }
  return JS.numberToString(rounded)
}

private struct UnitInfo {
  let dim: String
  let factor: Double
  let label: String
}

private let unitTable: (names: [String], map: [String: UnitInfo]) = {
  var names: [String] = []
  var map: [String: UnitInfo] = [:]
  func units(_ dim: String, _ factor: Double, _ label: String, _ aliases: String...) {
    for name in [label] + aliases {
      let key = JS.lower(name)
      if map[key] == nil { names.append(key) }
      map[key] = UnitInfo(dim: dim, factor: factor, label: label)
    }
  }
  units("length", 1, "m", "meter", "meters", "metre", "metres")
  units("length", 1000, "km", "kilometer", "kilometers", "kilometre", "kilometres")
  units("length", 0.01, "cm", "centimeter", "centimeters")
  units("length", 0.001, "mm", "millimeter", "millimeters")
  units("length", 1609.344, "mi", "mile", "miles")
  units("length", 0.9144, "yd", "yard", "yards")
  units("length", 0.3048, "ft", "foot", "feet")
  units("length", 0.0254, "in", "inch", "inches")
  units("length", 1852, "nmi", "nautical mile")
  units("mass", 1, "kg", "kilogram", "kilograms", "kilo", "kilos")
  units("mass", 0.001, "g", "gram", "grams")
  units("mass", 1e-6, "mg", "milligram", "milligrams")
  units("mass", 0.45359237, "lb", "lbs", "pound", "pounds")
  units("mass", 0.028349523125, "oz", "ounce", "ounces")
  units("mass", 6.35029318, "st", "stone", "stones")
  units("mass", 1000, "t", "tonne", "tonnes")
  units("volume", 1, "l", "liter", "liters", "litre", "litres")
  units("volume", 0.001, "ml", "milliliter", "milliliters", "millilitre", "millilitres")
  units("volume", 3.785411784, "gal", "gallon", "gallons")
  units("volume", 0.946352946, "qt", "quart", "quarts")
  units("volume", 0.473176473, "pt", "pint", "pints")
  units("volume", 0.2365882365, "cup", "cups")
  units("volume", 0.0295735295625, "fl oz", "floz")
  units("volume", 0.01478676478125, "tbsp", "tablespoon", "tablespoons")
  units("volume", 0.00492892159375, "tsp", "teaspoon", "teaspoons")
  units("time", 0.001, "ms", "millisecond", "milliseconds")
  units("time", 1, "s", "sec", "secs", "second", "seconds")
  units("time", 60, "min", "mins", "minute", "minutes")
  units("time", 3600, "h", "hr", "hrs", "hour", "hours")
  units("time", 86400, "days", "day", "d")
  units("time", 604800, "weeks", "week", "wk")
  units("time", 31556952, "years", "year", "yr")
  units("data", 0.125, "bits", "bit")
  units("data", 1, "bytes", "byte", "B")
  units("data", 1e3, "KB", "kilobyte", "kilobytes")
  units("data", 1e6, "MB", "megabyte", "megabytes")
  units("data", 1e9, "GB", "gigabyte", "gigabytes")
  units("data", 1e12, "TB", "terabyte", "terabytes")
  units("data", 1024, "KiB")
  units("data", 1024 * 1024, "MiB")
  units("data", 1024 * 1024 * 1024, "GiB")
  units("data", 1024 * 1024 * 1024 * 1024, "TiB")
  units("speed", 1, "m/s")
  units("speed", 1000.0 / 3600, "km/h", "kph", "kmh")
  units("speed", 1609.344 / 3600, "mph")
  units("speed", 1852.0 / 3600, "knots", "knot", "kn")
  return (names, map)
}()

private enum Temperature: String {
  case c = "C", f = "F", k = "K"

  func toCelsius(_ v: Double) -> Double {
    switch self {
    case .c: v
    case .f: ((v - 32) * 5) / 9
    case .k: v - 273.15
    }
  }

  func fromCelsius(_ v: Double) -> Double {
    switch self {
    case .c: v
    case .f: (v * 9) / 5 + 32
    case .k: v + 273.15
    }
  }
}

private let temperatureNames = ["c", "°c", "celsius", "f", "°f", "fahrenheit", "k", "kelvin"]
private let temperatures: [String: Temperature] = [
  "c": .c, "°c": .c, "celsius": .c, "f": .f, "°f": .f, "fahrenheit": .f, "k": .k, "kelvin": .k,
]

private let conversion: Pattern = {
  let names = (unitTable.names + temperatureNames).enumerated()
    .sorted { $0.element.utf16.count != $1.element.utf16.count ? $0.element.utf16.count > $1.element.utf16.count : $0.offset < $1.offset }
    .map(\.element)
  let alternatives = names.map { name in
    name.map { c -> String in
      if c == "/" || c == "." { return "\\" + String(c) }
      if c == " " { return "\(space)*" }
      return caseless(String(c))
    }.joined()
  }.joined(separator: "|")
  let joiners = ["to", "in", "into", "as"].map(caseless).joined(separator: "|") + "|=|->|→"
  return Pattern("^([^\\n\\r\\u2028\\u2029]+?)\(space)*(\(alternatives))\(space)+(?:\(joiners))\(space)+(\(alternatives))\\z")
}()

private func convert(_ input: Units) -> (value: Double, unit: String)? {
  guard let m = conversion.firstMatch(input), let amount = evaluate(m[1]!) else { return nil }
  let from = JS.collapseSpaces(JS.lower(m[2]!)).string
  let to = JS.collapseSpaces(JS.lower(m[3]!)).string
  if let tFrom = temperatures[from], let tTo = temperatures[to] {
    return (tTo.fromCelsius(tFrom.toCelsius(amount)), tTo == .k ? "K" : "°" + tTo.rawValue)
  }
  guard let a = unitTable.map[from], let b = unitTable.map[to], a.dim == b.dim else { return nil }
  return ((amount * a.factor) / b.factor, b.label)
}

public struct Calculation: Sendable, Equatable {
  public var expression: String
  public var value: Double
  public var display: String
}

private let leadingEquals = Pattern("^=\(space)*")
private let trailingEquals = Pattern("\(space)*=\(space)*\\??\\z")
private let calculable = Pattern("[0-9\(piTau)]|(?<![A-Za-z0-9_])(\(caseless("pi"))|[eE]|\(caseless("tau")))(?![A-Za-z0-9_])")
private let isoDate = Pattern("^[0-9]{4}-[0-9]{1,2}-[0-9]{1,2}\\z")
private let dottedVersion = Pattern("^[0-9]+(\\.[0-9]+){2,}\\z")
private let hasOperatorPattern = Pattern(
  "[A-Za-z0-9_).\(piTau)]\(space)*(\\*\\*|[-+*/^%×·÷−–]|\(caseless("mod"))|\(caseless("of"))|[xX])\(space)*[0-9(.a-zA-Z\(piTau)]"
)
private let trailingPostfix = Pattern("[!%°]\(space)*\\z")
private let hasFunctionPattern = Pattern(
  "(?<![A-Za-z0-9_])(\(functionNames.map(caseless).joined(separator: "|")))\(space)*\\("
)

public func calculate(_ raw: String) -> Calculation? {
  var expression = JS.trim(raw.units)
  if let m = leadingEquals.firstMatch(expression) { expression.removeSubrange(0..<m.end) }
  if let m = trailingEquals.firstMatch(expression) { expression.removeSubrange(m.range.location..<m.end) }
  if expression.isEmpty || expression.count > 200 || !calculable.test(expression) { return nil }
  if isoDate.test(expression) || dottedVersion.test(expression) { return nil }
  let text = expression.string
  if let converted = convert(expression) {
    return Calculation(expression: text, value: converted.value, display: "\(formatNumber(converted.value, 9)) \(converted.unit)")
  }
  let hasOperator = hasOperatorPattern.test(expression) || trailingPostfix.test(expression)
  if !hasOperator && !hasFunctionPattern.test(expression) { return nil }
  guard let value = evaluate(expression) else { return nil }
  return Calculation(expression: text, value: value, display: formatNumber(value))
}
