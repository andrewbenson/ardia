import Foundation

public enum PanePromptSpecs {
  public static let margin: Double = 8

  public static func site(_ origin: String) -> String {
    guard let host = URL(string: origin)?.host, !host.isEmpty else { return origin }
    return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
  }

  public static func password(_ prompt: PanePasswordPrompt, chosen: String?) -> [String: Any] {
    let site = site(prompt.origin)
    let username = chosen ?? prompt.username
    let choices = prompt.update && prompt.usernames.count > 1 ? prompt.usernames : []
    let detail: [String: Any]
    if choices.isEmpty {
      var lines: [[String: Any]] = [[
        "text": username.isEmpty ? (prompt.federation.isEmpty ? "No username" : "Signed in with \(Self.site(prompt.federation))") : username,
        "strong": true, "maxLines": 1,
      ]]
      if prompt.passwordLength > 0 {
        lines.append(["text": String(repeating: "•", count: min(prompt.passwordLength, 16)), "tone": "secondary", "kern": 1, "maxLines": 1])
      }
      detail = ["kind": "well", "sections": [["lines": lines]]]
    } else {
      detail = ["kind": "choices", "choices": choices.map { ["id": $0, "title": $0, "selected": $0 == username] }]
    }
    var buttons: [[String: Any]] = []
    if !prompt.update { buttons.append(["id": "never", "title": "Never on This Site"]) }
    buttons.append(["id": prompt.update ? "nope" : "dismiss", "title": "Not Now"])
    buttons.append(["id": prompt.update ? "update" : "save", "title": prompt.update ? "Update" : "Save", "primary": true])
    return [
      "popover": ["width": prompt.update ? 310 : 350, "top": margin, "right": margin, "modal": false],
      "icons": ["key.fill"],
      "title": prompt.update ? "Update saved password?" : "Save password for \(site)?",
      "message": prompt.update ? "It will be auto-filled on \(site)" : "That way, it'll be auto-filled next time",
      "details": [detail],
      "buttons": buttons,
      "close": true,
    ]
  }
}

public struct PromptInputGuard {
  public static let delay: TimeInterval = 0.5
  public static let openDuration: TimeInterval = 0.15
  private var visibleAt = Double.infinity
  private var lastInputAt: Double = 0

  public init() {}

  public mutating func shown(at now: TimeInterval) { visibleAt = now + Self.openDuration }

  public mutating func allow(at now: TimeInterval, activatedAt: TimeInterval) -> Bool {
    let previous = lastInputAt
    lastInputAt = now
    return now >= max(visibleAt, activatedAt) + Self.delay && now - previous >= Self.delay
  }
}
