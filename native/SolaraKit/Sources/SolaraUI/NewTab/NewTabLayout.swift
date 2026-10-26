import CoreGraphics
import Foundation

public enum NewTabLayout {
  public static let barHeight: CGFloat = 112
  public static let barBorder: CGFloat = 0.5
  public static let barRadius: CGFloat = 20
  public static let markSize: CGFloat = 100
  public static let diaOffset: CGFloat = 1
  public static let markAboveBar: CGFloat = 84.1
  public static let headingGapAboveMark: CGFloat = 12
  public static let headingEdge: CGFloat = 16
  static let centreLift: CGFloat = 158
  static let minCentredTop: CGFloat = 100
  static let barDrop: CGFloat = 38

  public static func barWidth(_ viewWidth: CGFloat) -> CGFloat {
    let content: CGFloat = viewWidth < 708 ? (viewWidth <= 636 ? viewWidth - 20 : 616) : viewWidth < 1700 ? 652 : 774
    return min(content, viewWidth - 28)
  }

  public static func barTop(height: CGFloat, under: CGFloat, headingHeight: CGFloat = 0) -> CGFloat {
    let centred = max((height - under) / 2 - centreLift, minCentredTop) + barDrop + diaOffset + under
    return max(centred, under + headingTopReserve(headingHeight))
  }

  public static func headingTopReserve(_ headingHeight: CGFloat) -> CGFloat {
    headingHeight > 0 ? headingEdge + headingHeight + headingGapAboveMark + markAboveBar : 0
  }

  public static func headingTop(barTop: CGFloat, headingHeight: CGFloat) -> CGFloat {
    barTop - markAboveBar - headingGapAboveMark - headingHeight
  }

  public static func roundToPixel(_ value: CGFloat, scale: CGFloat) -> CGFloat {
    (value * scale + 0.5).rounded(.down) / scale
  }

  public struct Frames: Equatable, Sendable {
    public var bar: CGRect
    public var mark: CGRect
    public var headingTop: CGFloat
  }

  public static func frames(size: CGSize, under: CGFloat, headingHeight: CGFloat, barHeight: CGFloat, scale: CGFloat) -> Frames {
    let width = barWidth(size.width)
    let x = max(size.width / 2 - width / 2, 14) + diaOffset
    let top = barTop(height: size.height, under: under, headingHeight: headingHeight)
    let markTop = roundToPixel(top - markAboveBar, scale: scale)
    let markLeft = roundToPixel(size.width / 2 + diaOffset - markSize / 2, scale: scale)
    return Frames(
      bar: CGRect(x: x, y: top, width: width, height: barHeight),
      mark: CGRect(x: markLeft, y: markTop, width: markSize, height: top - markTop),
      headingTop: headingTop(barTop: top, headingHeight: headingHeight))
  }
}
