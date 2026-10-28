import Observation
import SwiftUI

public enum LiveCardEvent: Equatable, Sendable {
  case height(Double)
  case activate
  case join(String, all: Bool)
  case refresh
  case connect
  case dismiss
  case view
}

public struct LiveCardEvent_Row: Decodable, Equatable, Sendable, Identifiable {
  public var id: String
  public var title: String
  public var color: String
  public var time: String?
  public var when: String?
  public var running: Bool?
  public var past: Bool?
  public var joinTitle: String?
  public var people: [String]?
}

@MainActor
@Observable
public final class LiveCardModel {
  public struct State: Decodable, Equatable, Sendable {
    public var card: String
    public var dark: Bool
    public var nowColor: String
    public var date: String?
    public var connected: Bool?
    public var loading: Bool?
    public var body: String?
    public var product: String?
    public var allDay: [LiveCardEvent_Row]?
    public var events: [LiveCardEvent_Row]?
    public var alert: LiveCardEvent_Row?
    public var calendarName: String?
    public var who: String?
    public var viewEvent: Bool?
    public var openAll: String?
  }

  public var state: State?
  @ObservationIgnored public var onEvent: (LiveCardEvent) -> Void = { _ in }

  public init() {}

  public func apply(json: String) {
    guard let data = json.data(using: .utf8), let next = try? JSONDecoder().decode(State.self, from: data) else { return }
    if next != state { state = next }
  }
}

public struct LiveCardView: View {
  let model: LiveCardModel

  public init(model: LiveCardModel) {
    self.model = model
  }

  public var body: some View {
    Group {
      if let state = model.state {
        if state.card == "meetingAlert" {
          MeetingAlertCard(state: state, onEvent: model.onEvent)
        } else {
          CalendarPreviewCard(state: state, onEvent: model.onEvent)
        }
      }
    }
    .fixedSize(horizontal: false, vertical: true)
    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { model.onEvent(.height(Double($0))) }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    .preferredColorScheme(model.state?.dark == true ? .dark : .light)
  }
}

struct LivePersonStack: View {
  let people: [String]
  var size: CGFloat = 18

  var body: some View {
    let shown = Array(people.prefix(3))
    HStack(spacing: -size * 0.35) {
      ForEach(Array(shown.enumerated()), id: \.offset) { _, name in
        Circle()
          .fill(Color.secondary.opacity(0.35))
          .overlay(Text(Self.initials(name)).font(.system(size: size * 0.42, weight: .semibold)))
          .overlay(Circle().strokeBorder(Color(nsColor: .windowBackgroundColor), lineWidth: 1.5))
          .frame(width: size, height: size)
      }
      if people.count > shown.count {
        Text("+\(people.count - shown.count)").font(.caption2).foregroundStyle(.secondary).padding(.leading, size * 0.35 + 3)
      }
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(people.joined(separator: ", "))
  }

  static func initials(_ name: String) -> String {
    let parts = name.split(whereSeparator: { " ._-".contains($0) }).prefix(2)
    let text = parts.compactMap { $0.first.map { String($0).uppercased() } }.joined()
    return text.isEmpty ? "?" : text
  }
}

struct CalendarPreviewCard: View {
  let state: LiveCardModel.State
  let onEvent: (LiveCardEvent) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: 6) {
        Text("Today").font(.system(size: 13, weight: .semibold))
        Text(state.date ?? "").font(.system(size: 12)).foregroundStyle(.secondary)
        Spacer(minLength: 0)
        if state.connected == true {
          Button { onEvent(.refresh) } label: {
            Image(systemName: "arrow.clockwise").font(.system(size: 10, weight: .semibold))
              .symbolEffect(.rotate, options: .repeat(.continuous), isActive: state.loading == true)
          }
          .buttonStyle(.borderless)
          .help("Refresh")
          .accessibilityLabel("Refresh")
          .pageProbe("Refresh")
        }
      }
      .padding(.bottom, 8)
      switch state.body {
      case "signIn":
        (Text("Connect your calendar").foregroundStyle(Color.accentColor) + Text(" to see your meetings here and get alerts before they start."))
          .font(.system(size: 12.5))
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
          .onTapGesture { onEvent(.connect) }
          .accessibilityAddTraits(.isLink)
      case "denied":
        Text("Allow \(state.product ?? "Solara") in System Settings › Privacy & Security › Calendars to see your meetings here.")
          .font(.system(size: 12.5))
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      case "events":
        VStack(alignment: .leading, spacing: 2) {
          ForEach(state.allDay ?? []) { e in
            HStack(spacing: 7) {
              RoundedRectangle(cornerRadius: 2).fill(Color(themeHex: e.color)).frame(width: 7, height: 7)
              Text(e.title).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
              Spacer(minLength: 0)
              Text("All day").font(.system(size: 11)).foregroundStyle(.tertiary)
            }
            .frame(height: 22)
            .padding(.horizontal, 4)
          }
          ForEach(state.events ?? []) { e in
            CalendarEventRow(event: e, nowColor: state.nowColor, onEvent: onEvent)
          }
        }
      default:
        Text(state.body == "loading" ? "Loading events" : state.body == "error" ? "Couldn't load events" : state.body == "noMore" ? "No more events today" : "No events today")
          .font(.system(size: 12.5))
          .foregroundStyle(.secondary)
          .padding(.vertical, 6)
      }
    }
  }
}

struct CalendarEventRow: View {
  let event: LiveCardEvent_Row
  let nowColor: String
  let onEvent: (LiveCardEvent) -> Void
  @State private var hovered = false

  var body: some View {
    HStack(spacing: 8) {
      RoundedRectangle(cornerRadius: 1.5).fill(Color(themeHex: event.color)).frame(width: 3)
      VStack(alignment: .leading, spacing: 2) {
        Text(event.title).font(.system(size: 13, weight: .medium)).lineLimit(1)
        (Text(event.time ?? "") + Text(" · \(event.when ?? "")").fontWeight(.medium).foregroundColor(event.running == true ? Color(themeHex: nowColor) : .secondary))
          .font(.system(size: 11.5))
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }
      Spacer(minLength: 0)
      if let joinTitle = event.joinTitle {
        Button { onEvent(.join(event.id, all: false)) } label: { Label("Join", systemImage: "video.fill") }
          .buttonStyle(.borderedProminent)
          .controlSize(.small)
          .help(joinTitle)
      } else if let people = event.people, !people.isEmpty {
        LivePersonStack(people: people)
      }
    }
    .padding(.vertical, 6)
    .padding(.horizontal, 4)
    .background(RoundedRectangle(cornerRadius: 8).fill(hovered ? Color.primary.opacity(0.06) : .clear))
    .opacity(event.past == true ? 0.5 : 1)
    .contentShape(Rectangle())
    .onHover { hovered = $0 }
    .onTapGesture { onEvent(.activate) }
    .accessibilityElement(children: .combine)
    .accessibilityAddTraits(.isButton)
    .pageProbe("event:\(event.id)")
  }
}

struct MeetingAlertCard: View {
  let state: LiveCardModel.State
  let onEvent: (LiveCardEvent) -> Void

  var body: some View {
    let e = state.alert
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 6) {
        RoundedRectangle(cornerRadius: 2.5).fill(Color(themeHex: e?.color ?? "#888888")).frame(width: 8, height: 8)
        (Text(e?.when ?? "").fontWeight(.medium).foregroundColor(e?.running == true ? Color(themeHex: state.nowColor) : .secondary)
          + Text(state.calendarName.map { " · \($0)" } ?? "").foregroundColor(.secondary))
          .font(.system(size: 11.5))
          .lineLimit(1)
        Spacer(minLength: 0)
        Button { onEvent(.dismiss) } label: { Image(systemName: "xmark").font(.system(size: 9, weight: .semibold)) }
          .buttonStyle(.borderless)
          .help("Ignore")
          .accessibilityLabel("Ignore")
          .pageProbe("Ignore")
      }
      VStack(alignment: .leading, spacing: 2) {
        Text(e?.title ?? "").font(.system(size: 14, weight: .semibold)).lineLimit(2).fixedSize(horizontal: false, vertical: true)
        Text(e?.time ?? "").font(.system(size: 12)).foregroundStyle(.secondary)
      }
      if let people = e?.people, !people.isEmpty {
        HStack(spacing: 7) {
          LivePersonStack(people: people, size: 20)
          Text(state.who ?? "").font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
        }
      }
      VStack(spacing: 6) {
        if let joinTitle = e?.joinTitle {
          Button { onEvent(.join(e?.id ?? "", all: false)) } label: { Label(joinTitle, systemImage: "video.fill").frame(maxWidth: .infinity) }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
            .pageProbe("Join")
        } else if state.viewEvent == true {
          Button { onEvent(.view) } label: { Label("View Event", systemImage: "calendar").frame(maxWidth: .infinity) }
            .controlSize(.large)
        }
        if e?.joinTitle != nil, let tip = state.openAll {
          Button { onEvent(.join(e?.id ?? "", all: true)) } label: { Label("Open All and Join", systemImage: "square.stack").frame(maxWidth: .infinity) }
            .controlSize(.large)
            .help(tip)
            .pageProbe("Open All and Join")
        }
      }
      .padding(.top, 2)
    }
    .padding(12)
    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5))
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Meeting alert")
  }
}
