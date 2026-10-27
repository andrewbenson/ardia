import AppKit
import SolaraOmnibox
import SwiftUI

enum PageMetrics {
  static let width: CGFloat = 880
  static let header: CGFloat = 64
}

struct PageHeader<Actions: View>: View {
  @Environment(\.pageTheme) private var theme
  let title: String
  @Binding var query: String
  let placeholder: String
  var focus = 0
  @ViewBuilder var actions: () -> Actions

  var body: some View {
    HStack(spacing: 16) {
      Text(title)
        .font(.system(size: 22, weight: .semibold))
        .foregroundStyle(theme.textPrimary)
        .lineLimit(1)
        .offset(y: -0.5)
        .frame(width: 200, alignment: .leading)
        .accessibilityAddTraits(.isHeader)
      PageSearchField(text: $query, placeholder: placeholder, focus: focus)
        .frame(maxWidth: 480)
        .frame(maxWidth: .infinity)
      HStack(spacing: 8) { actions() }
        .frame(width: 200, alignment: .trailing)
    }
    .padding(.horizontal, 24)
    .frame(height: PageMetrics.header)
  }
}

struct PageEmptyState: View {
  @Environment(\.pageTheme) private var theme
  let icon: String
  let title: String
  var subtitle: String?

  var body: some View {
    VStack(spacing: 8) {
      Image(systemName: icon).font(.system(size: 30)).foregroundStyle(theme.textTertiary).frame(width: 40, height: 40)
      Text(title).font(.system(size: 15, weight: .medium)).foregroundStyle(theme.textSecondary)
      if let subtitle {
        Text(subtitle).font(.system(size: 13)).foregroundStyle(theme.textTertiary).multilineTextAlignment(.center).frame(maxWidth: 360)
      }
    }
    .padding(.bottom, 80)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}

public enum PageFormat {
  static let days = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]
  static let months = ["January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December"]

  public static func dayStart(_ ms: Double, calendar: Calendar = .current) -> Double {
    calendar.startOfDay(for: Date(timeIntervalSince1970: ms / 1000)).timeIntervalSince1970 * 1000
  }

  public static func nextDay(_ start: Double, calendar: Calendar = .current) -> Double {
    let date = calendar.date(byAdding: .day, value: 1, to: Date(timeIntervalSince1970: start / 1000)) ?? Date(timeIntervalSince1970: start / 1000 + 86400)
    return calendar.startOfDay(for: date).timeIntervalSince1970 * 1000
  }

  public static func dayLabel(_ start: Double, now: Double = Date().timeIntervalSince1970 * 1000, calendar: Calendar = .current) -> String {
    let date = Date(timeIntervalSince1970: start / 1000)
    let parts = calendar.dateComponents([.weekday, .month, .day, .year], from: date)
    let full = "\(days[(parts.weekday ?? 1) - 1]), \(months[(parts.month ?? 1) - 1]) \(parts.day ?? 1), \(parts.year ?? 1970)"
    let today = dayStart(now, calendar: calendar)
    if start == today { return "Today – \(full)" }
    if start == dayStart(today - 1, calendar: calendar) { return "Yesterday – \(full)" }
    return full
  }

  public static func timeLabel(_ ms: Double, calendar: Calendar = .current) -> String {
    let parts = calendar.dateComponents([.hour, .minute], from: Date(timeIntervalSince1970: ms / 1000))
    let h = parts.hour ?? 0
    let m = parts.minute ?? 0
    return "\(h % 12 == 0 ? 12 : h % 12):\(m < 10 ? "0" : "")\(m) \(h < 12 ? "AM" : "PM")"
  }

  public static func hostLabel(_ url: String) -> String {
    if let app = appUrlOrigin(url) { return app }
    guard let match = url.range(of: #"^[a-zA-Z][a-zA-Z0-9+.-]*://([^/?#:]+)"#, options: .regularExpression) else { return url }
    let prefix = url[match]
    guard let start = prefix.range(of: "://") else { return url }
    let host = String(prefix[start.upperBound...]).lowercased()
    let shown = displayHost(host)
    return shown.hasPrefix("www.") ? String(shown.dropFirst(4)) : shown
  }

  public static func queryWords(_ query: String) -> [String] {
    query.lowercased().split(whereSeparator: { $0.isWhitespace }).map(String.init)
  }

  public static func searchText(_ fields: String...) -> String {
    searchText(fields)
  }

  public static func searchText(_ fields: [String]) -> String {
    fields.map { $0.range(of: "xn--", options: .caseInsensitive) != nil ? "\($0) \(urlForDisplay($0))" : $0 }.joined(separator: " ").lowercased()
  }

  public static func matches(_ query: String, _ fields: String...) -> Bool {
    let words = queryWords(query)
    if words.isEmpty { return true }
    let hay = searchText(fields)
    return words.allSatisfy { hay.contains($0) }
  }
}
