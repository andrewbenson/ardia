import Observation
import SwiftUI

public enum CreateProfileEvent: Equatable, Sendable {
  case create(name: String, color: String, shareWith: String?)
  case cancel
}

@MainActor
@Observable
public final class CreateProfileFormModel: CreateProfileSource {
  public struct Profile: Decodable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var color: String
    public var dataId: String?
  }

  public struct State: Decodable, Equatable, Sendable {
    public var key: String
    public var profiles: [Profile]
    public var current: String
    public var presetName: String?
    public var presetShareWith: String?
    public var dark: Bool
  }

  public var profiles: [ProfileSummary] = []
  public var current = ""
  public var presetName = ""
  public var presetShareWith: String?
  public var key = ""
  public var dark = false
  @ObservationIgnored public var onEvent: (CreateProfileEvent) -> Void = { _ in }
  @ObservationIgnored private var finished = false

  public init() {}

  func create(name: String, color: ProfileColorValue, shareWith: String?) -> String {
    finished = true
    onEvent(.create(name: name, color: color.rawValue, shareWith: shareWith))
    return ""
  }

  func cancel() {
    guard !finished else { return }
    finished = true
    onEvent(.cancel)
  }

  public func apply(json: String) {
    guard let data = json.data(using: .utf8), let state = try? JSONDecoder().decode(State.self, from: data) else { return }
    let next = state.profiles.map { ProfileSummary(id: $0.id, name: $0.name, color: ProfileColorValue(rawValue: $0.color) ?? .plum, dataId: $0.dataId) }
    if next != profiles { profiles = next }
    current = state.current
    dark = state.dark
    if key != state.key {
      presetName = state.presetName ?? ""
      presetShareWith = state.presetShareWith
      finished = false
      key = state.key
    }
  }
}

public struct CreateProfileFormView: View {
  let model: CreateProfileFormModel

  public init(model: CreateProfileFormModel) {
    self.model = model
  }

  public var body: some View {
    ZStack {
      Rectangle()
        .fill(Color.black.opacity(model.dark ? 0.35 : 0.15))
        .contentShape(Rectangle())
        .onTapGesture { model.cancel() }
        .accessibilityHidden(true)
      if !model.key.isEmpty {
        CreateProfileSheet(model: model, current: model.current, presetName: model.presetName, presetShareWith: model.presetShareWith) { model.cancel() }
          .id(model.key)
          .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
          .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5))
          .shadow(color: .black.opacity(model.dark ? 0.45 : 0.18), radius: 30, y: 12)
          .contentShape(Rectangle())
          .onTapGesture {}
          .onExitCommand { model.cancel() }
          .accessibilityElement(children: .contain)
          .accessibilityAddTraits(.isModal)
      }
    }
    .preferredColorScheme(model.dark ? .dark : .light)
  }
}
