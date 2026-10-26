import Foundation
import SwiftUI

public enum SettingValue: Hashable, Sendable {
  case null
  case bool(Bool)
  case number(Double)
  case string(String)
  case array([SettingValue])
  case object([String: SettingValue])

  public var bool: Bool? { if case .bool(let v) = self { v } else { nil } }
  public var string: String? { if case .string(let v) = self { v } else { nil } }
  public var number: Double? { if case .number(let v) = self { v } else { nil } }
  public var object: [String: SettingValue]? { if case .object(let v) = self { v } else { nil } }
  public var array: [SettingValue]? { if case .array(let v) = self { v } else { nil } }
}

public struct SettingsProfile: Hashable, Sendable, Identifiable {
  public let id: String
  public let name: String
  public let engineProfile: String

  public init(id: String, name: String, engineProfile: String) {
    self.id = id
    self.name = name
    self.engineProfile = engineProfile
  }
}

@MainActor
public protocol SettingsStoreSource: AnyObject {
  func settingValue(_ key: String) -> SettingValue?
  func updateSettings(_ patch: [String: SettingValue])
  var profiles: [SettingsProfile] { get }
  var topTabLayout: Bool { get }
  func chooseTabLayout(_ layout: String)
}

public extension SettingsStoreSource {
  func engineProfile(_ profileId: String) -> String {
    profiles.first { $0.id == profileId }?.engineProfile ?? profileId
  }

  func bool(_ key: String) -> Bool { settingValue(key)?.bool ?? false }
  func string(_ key: String) -> String { settingValue(key)?.string ?? "" }

  func set(_ key: String, _ value: Bool) { updateSettings([key: .bool(value)]) }
  func set(_ key: String, _ value: String) { updateSettings([key: .string(value)]) }

  func toggle(_ key: String) -> Binding<Bool> {
    Binding(get: { self.bool(key) }, set: { self.set(key, $0) })
  }

  func choice(_ key: String) -> Binding<String> {
    Binding(get: { self.string(key) }, set: { self.set(key, $0) })
  }
}
