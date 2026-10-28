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

public enum PanePromptKind: String, CaseIterable, Sendable {
  case password, autofill, externalApp, popups, permission

  public var leftWidth: Double? {
    switch self {
    case .externalApp: PanePromptSpecs.externalAppWidth
    case .permission: PanePromptSpecs.permissionWidth
    default: nil
    }
  }
}

extension PanePromptSpecs {
  public static let externalAppWidth: Double = 340

  public static func externalAppLeft(urlLeft: Double, paneWidth: Double) -> Double {
    promptLeft(urlLeft: urlLeft, paneWidth: paneWidth, width: externalAppWidth)
  }

  public static func autofill(_ prompt: PaneAutofillPrompt) -> [String: Any] {
    func lines(_ texts: [String], ranked: Bool) -> [[String: Any]] {
      texts.enumerated().map { i, text in
        ranked ? ["text": text, "strong": i == 0, "tone": i == 0 ? "primary" : "secondary", "maxLines": 2] : ["text": text, "maxLines": 2]
      }
    }
    let to = prompt.changes.map(\.to).filter { !$0.isEmpty }
    let from = prompt.changes.map(\.from).filter { !$0.isEmpty }
    let sections: [[String: Any]]
    if prompt.kind != "updateAddress" {
      sections = [["lines": lines(prompt.lines, ranked: true)]]
    } else if let newLabel = prompt.newLabel {
      sections = [["label": newLabel, "lines": lines(to, ranked: false)], ["label": prompt.oldLabel ?? "", "lines": lines(from, ranked: false)]]
    } else {
      sections = [["lines": lines(to, ranked: true)]]
    }
    var details: [[String: Any]] = [["kind": "well", "sections": sections]]
    if !prompt.footer.isEmpty { details.append(["kind": "note", "text": prompt.footer]) }
    return [
      "popover": ["width": 350, "top": margin, "right": margin, "modal": false],
      "icons": [prompt.kind == "saveCard" ? "creditcard.fill" : "mappin.and.ellipse"],
      "title": prompt.title,
      "message": prompt.message.isEmpty ? NSNull() : prompt.message,
      "details": details,
      "buttons": [["id": "decline", "title": prompt.decline], ["id": "accept", "title": prompt.accept, "primary": true]],
      "close": true,
    ]
  }

  public static func externalApp(_ request: PaneExternalApp, always: Bool, left: Double) -> [String: Any] {
    [
      "popover": ["width": externalAppWidth, "top": margin, "left": left, "modal": false],
      "icons": request.icon != nil ? [] : [request.app != nil ? "app" : "questionmark.app.dashed"],
      "image": request.icon ?? NSNull(),
      "title": request.title,
      "message": request.message ?? NSNull(),
      "details": request.remember.map { [["kind": "checkbox", "label": $0, "value": always] as [String: Any]] } ?? [],
      "buttons": request.app != nil ? [["id": "cancel", "title": "Cancel"], ["id": "open", "title": "Open", "primary": true]] : [["id": "ok", "title": "OK", "primary": true]],
      "close": true,
    ]
  }

  public static let popupsWidth: Double = 360

  public static func popups(_ hint: [String: Any]) -> (key: String, spec: [String: Any])? {
    let list = (hint["list"] as? [[String: Any]] ?? []).compactMap { row -> (id: String, url: String, origin: String)? in
      guard let id = row["id"] as? String else { return nil }
      return (id, row["url"] as? String ?? "", row["origin"] as? String ?? "")
    }
    guard let first = list.first else { return nil }
    let site = site(first.origin)
    let side: [String: Any] = hint["side"] as? String == "left" ? ["left": margin] : ["right": margin]
    let rows = list.suffix(5).map { popup -> [String: Any] in
      let title = popup.url.replacingOccurrences(of: "^https?://", with: "", options: .regularExpression)
      return ["id": popup.id, "icon": "arrow.up.forward.app", "title": title.isEmpty ? "about:blank" : title]
    }
    let spec: [String: Any] = [
      "popover": ["width": popupsWidth, "top": margin].merging(side) { a, _ in a },
      "icons": ["macwindow.badge.plus"],
      "title": "Always allow pop-ups from \(site)?",
      "message": "Allow \(site) to always open pop-up windows, choose every time, or always deny pop-ups.",
      "details": [] as [Any],
      "buttons": [["id": "deny", "title": "Always Deny"], ["id": "once", "title": "Only Once"], ["id": "allow", "title": "Always Allow", "primary": true]],
      "close": false,
      "rows": rows,
      "rowsMore": list.count > 5 ? "and \(list.count - 5) more" : NSNull(),
    ]
    return (first.origin + "\u{1}" + first.id, spec)
  }
}
