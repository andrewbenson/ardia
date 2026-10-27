import SwiftUI

@MainActor
public enum PageProbe {
  public struct Item: Sendable {
    public var label: String
    public var frame: CGRect
    var owner: UUID
  }

  public static var enabled = false
  public static var items: [String: Item] = [:]

  static func record(_ label: String, _ frame: CGRect, owner: UUID) {
    items[label] = Item(label: label, frame: frame, owner: owner)
  }

  static func forget(_ label: String, owner: UUID) {
    if items[label]?.owner == owner { items[label] = nil }
  }
}

struct PageProbeFrame: ViewModifier {
  let label: String
  @State private var id = UUID()
  @State private var frame: CGRect?

  func body(content: Content) -> some View {
    if PageProbe.enabled {
      content
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { next in
          frame = next
          PageProbe.record(label, next, owner: id)
        }
        .onAppear { if let frame { PageProbe.record(label, frame, owner: id) } }
        .onDisappear { PageProbe.forget(label, owner: id) }
    } else {
      content
    }
  }
}

extension View {
  func pageProbe(_ label: String) -> some View { modifier(PageProbeFrame(label: label)) }
}
