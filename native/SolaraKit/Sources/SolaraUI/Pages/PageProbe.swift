import SwiftUI

@MainActor
public enum PageProbe {
  public struct Item: Sendable {
    public var label: String
    public var frame: CGRect
  }

  public static var enabled = false
  public static var items: [UUID: Item] = [:]
}

struct PageProbeFrame: ViewModifier {
  let label: String
  @State private var id = UUID()

  func body(content: Content) -> some View {
    if PageProbe.enabled {
      content
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
          PageProbe.items[id] = PageProbe.Item(label: label, frame: frame)
        }
        .onDisappear { PageProbe.items[id] = nil }
    } else {
      content
    }
  }
}

extension View {
  func pageProbe(_ label: String) -> some View { modifier(PageProbeFrame(label: label)) }
}
