import CoreGraphics

public enum ShellMetrics {
  public static let sidebarWidth: CGFloat = 190
  public static let cardTop: CGFloat = 6
  public static let cardInset: CGFloat = 7
  public static let cardRadius: CGFloat = 10
  public static let toolbarHeight: CGFloat = 41
  public static let toolbarIconCenters: [CGFloat] = [21, 56, 92, 127]
  public static let breadcrumbX: CGFloat = 153
  public static let topStripHeight: CGFloat = 42
  public static let topCardInset: CGFloat = 6
  public static let paneGap: CGFloat = 7
  public static let minPane: CGFloat = 220
  public static let peekOrigin = CGPoint(x: 5, y: 5)
  public static let peekBottom: CGFloat = 5
  public static let peekRadius: CGFloat = 12
  public static let edgeStripWidth: CGFloat = 8
  public static let holdSlack: CGFloat = 24

  public static let lightsCenter = CGPoint(x: 25, y: 27)
  public static let arcLightsCenter = CGPoint(x: 25, y: 24)
  public static let topStripLightsCenter = CGPoint(x: 20.75, y: 20.75)
}

public struct ShellInset: Equatable, Sendable {
  public var top: CGFloat
  public var right: CGFloat
  public var bottom: CGFloat
  public var left: CGFloat

  public init(top: CGFloat, right: CGFloat, bottom: CGFloat, left: CGFloat) {
    self.top = top
    self.right = right
    self.bottom = bottom
    self.left = left
  }

  public static let sidebar = ShellInset(top: ShellMetrics.cardTop, right: ShellMetrics.cardInset, bottom: ShellMetrics.cardInset, left: ShellMetrics.cardInset)
  public static let topTabs = ShellInset(top: ShellMetrics.topStripHeight, right: ShellMetrics.topCardInset, bottom: ShellMetrics.topCardInset, left: ShellMetrics.topCardInset)
}
