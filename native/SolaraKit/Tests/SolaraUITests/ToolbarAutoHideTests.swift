import AppKit
import QuartzCore
import Testing
@testable import SolaraUI

@MainActor
struct ToolbarAutoHideTests {
  @Test func autoHideFadesScalesLiftsAndGoesClickThrough() {
    let bar = ToolbarView(frame: NSRect(x: 0, y: 0, width: 200, height: 40))
    bar.setAutoHide(opacity: 0.45, scale: 0.94, lift: 4.23, interactive: false)
    #expect(bar.alphaValue == 0.45)
    let t = bar.layer!.sublayerTransform
    #expect(abs(t.m11 - 0.94) < 1e-9 && abs(t.m22 - 0.94) < 1e-9)
    #expect(abs(t.m42 - (20 * 0.06 - 4.23)) < 1e-9)
    #expect(bar.hitTest(NSPoint(x: 10, y: 10)) == nil)
    bar.setAutoHide(opacity: 1, scale: 1, lift: 0, interactive: true)
    #expect(CATransform3DIsIdentity(bar.layer!.sublayerTransform))
    #expect(bar.alphaValue == 1)
  }
}

final class FlippedBox: NSView {
  override var isFlipped: Bool { true }
}

@MainActor
struct ToolbarLiftDirectionTests {
  @Test func liftMovesTheBarUpOnScreenInsideAFlippedContainer() {
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: true)
    window.isReleasedWhenClosed = false
    let root = window.contentView!
    root.wantsLayer = true
    let card = FlippedBox(frame: root.bounds)
    card.wantsLayer = true
    root.addSubview(card)
    let bar = ToolbarView(frame: NSRect(x: 0, y: 0, width: 400, height: 40))
    card.addSubview(bar)
    root.layoutSubtreeIfNeeded()
    let probe = CALayer()
    probe.frame = CGRect(x: 0, y: 0, width: 10, height: 10)
    bar.layer!.addSublayer(probe)
    let before = probe.convert(probe.bounds, to: root.layer!)
    bar.setAutoHide(opacity: 1, scale: 1, lift: 10, interactive: true)
    let after = probe.convert(probe.bounds, to: root.layer!)
    let up = root.layer!.contentsAreFlipped() ? before.minY - after.minY : after.minY - before.minY
    #expect(abs(up - 10) < 0.001)
  }
}
