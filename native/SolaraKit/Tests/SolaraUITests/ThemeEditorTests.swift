import Foundation
import Testing
@testable import SolaraUI

struct ThemeEditorTests {
  func near(_ a: Double, _ b: Double, _ tolerance: Double = 1e-5) -> Bool { abs(a - b) <= tolerance }

  func near(_ c: ThemeRGBA, _ expected: [Double]) -> Bool {
    near(c.r, expected[0]) && near(c.g, expected[1]) && near(c.b, expected[2]) && near(c.a, expected[3])
  }

  func stops(_ theme: ProfileThemeValue, _ expected: [[Double]]) -> Bool {
    theme.stops.count == expected.count && zip(theme.stops, expected).allSatisfy { stop, e in
      near(stop.x, e[0]) && near(stop.y, e[1]) && near(stop.color.r, e[2]) && near(stop.color.g, e[3]) && near(stop.color.b, e[4])
    }
  }

  let starting = ThemeMath.starting(swatch: "#4691C3")
  let startingStops: [[Double]] = [
    [0.200145, 0.509335, 0.36, 0.84, 0.825735],
    [0.306295, 0.270918, 0.36, 0.441735, 0.84],
  ]

  @Test func padColorsMatchTheTypeScript() {
    #expect(near(ThemeMath.padColor(0.2, 0.7), [0.311556, 0.888444, 0.564521, 1]))
    #expect(near(ThemeMath.padColor(0.9, 0.1, lightness: 0.3), [0.6, 0, 0.45, 1]))
    #expect(near(ThemeMath.padColor(0.5, 0.5), [0.6, 0.6, 0.6, 1]))
    let position = ThemeMath.padPosition(ThemeRGBA(r: 0.8, g: 0.3, b: 0.4))
    #expect(near(position.x, 0.771708) && near(position.y, 0.442247))
  }

  @Test func startingAndAddedStopsMatchTheTypeScript() {
    #expect(stops(starting, startingStops))
    #expect(starting.intensity == 0.6 && starting.translucency == 1 && starting.mode == .auto && starting.angle == nil)
    let added = ThemeMath.withAddedStop(starting)
    #expect(stops(added, startingStops + [[0.658012, 0.244986, 0.84, 0.36, 0.825735]]))
    #expect(ThemeMath.withAddedStop(added) == added)
    #expect(ThemeMath.withoutStop(added, at: 1).stops.map(\.x) == [added.stops[0].x, added.stops[2].x])
    #expect(ThemeMath.withoutStop(ThemeMath.withoutStop(starting, at: 0), at: 0).stops.count == 1)
  }

  @Test func accentsAndColorsMatchTheTypeScript() {
    #expect(ThemeMath.accent(starting) == "#5D94D7")
    #expect(ThemeMath.accent(ThemeMath.withAddedStop(starting)) == "#9A78D5")
    #expect(ThemeMath.colorHex(ThemeRGBA(r: 0.5, g: 0.25, b: 1)) == "#8040FF")
    #expect(ThemeMath.underColor(starting, dark: false) == "#F5F5F5")
    #expect(ThemeMath.underColor(starting, dark: true) == "#222222")
    var layered = starting
    layered.translucency = 0.5
    layered.intensity = 0.3
    #expect(near(ThemeMath.layerAlpha(layered), 0.6825))
    var grainy = starting
    grainy.grain = 0.5
    grainy.texture = .denim
    #expect(near(ThemeMath.grainAlpha(grainy), 0.3))
  }

  @Test func editsMatchTheTypeScript() {
    #expect(ThemeMath.withAngle(starting, -45).angle == 315)
    #expect(ThemeMath.withAngle(starting, 382.5).angle == 23)
    #expect(near(ThemeMath.stopLightness(starting.stops[0]), 0.6))
    #expect(stops(ThemeMath.withStopLightness(starting, at: 0, 0.3), [[0.200145, 0.509335, 0.12, 0.48, 0.469301], startingStops[1]]))
    #expect(stops(ThemeMath.withStop(starting, at: 1, x: 0.1, y: 0.4), [startingStops[0], [0.1, 0.4, 0.270152, 0.775521, 0.929848]]))
  }

  @Test func readabilityMatchesTheTypeScript() {
    #expect(ThemeMath.readableDark(starting, dark: false) == false)
    #expect(ThemeMath.readableDark(starting, dark: true) == true)
    var pale = starting
    pale.stops = [ThemeStopValue(color: ThemeRGBA(r: 0.95, g: 0.95, b: 0.9), x: 0.5, y: 0.5)]
    #expect(ThemeMath.readableDark(pale, dark: true) == true)
    pale.mode = .light
    pale.stops = [ThemeStopValue(color: ThemeRGBA(r: 0.95, g: 0.93, b: 0.9), x: 0.5, y: 0.5)]
    let app = ThemeMath.shown(pale, appDark: true, source: .app)
    #expect(app.dark && app.requestedDark && app.look == pale)
    let own = ThemeMath.shown(pale, appDark: true, source: .own)
    #expect(!own.dark && !own.requestedDark)
  }

  @Test func resolveSwapsInTheDarkLook() {
    var theme = ThemeMath.withAddedStop(starting)
    theme.angle = 90
    var darkLook = starting.look
    darkLook.angle = 200
    theme.dark = darkLook
    let dark = ThemeMath.resolve(theme, dark: true)
    #expect(dark.stops == starting.stops && dark.angle == 200 && dark.dark == nil && dark.mode == .auto)
    let light = ThemeMath.resolve(theme, dark: false)
    #expect(light.stops.count == 3 && light.angle == 90 && light.dark == nil)
  }

  @Test func dialSnapsToNotches() {
    #expect(ThemeMath.snappedDialAngle(dx: 0, dy: -10) == 0)
    #expect(ThemeMath.snappedDialAngle(dx: 10, dy: 0) == 90)
    #expect(ThemeMath.snappedDialAngle(dx: 10, dy: 10.5) == 135)
    #expect(ThemeMath.snappedDialAngle(dx: 10, dy: -3) == 73)
    #expect(ThemeMath.snappedDialAngle(dx: -1, dy: -10) == 354)
    #expect(ThemeMath.snappedDialAngle(dx: -0.5, dy: -10) == 0)
  }

  @Test func padClampsToTheCircle() {
    let p = ThemeMath.insidePad(x: 1, y: 0.5)
    #expect(p.x == 1 && p.y == 0.5)
    let q = ThemeMath.insidePad(x: 1, y: 1)
    #expect(near(q.x, 0.5 + 0.5 / 2.squareRoot()) && near(q.y, 0.5 + 0.5 / 2.squareRoot()))
  }

  @Test func codableUsesTheStoreFieldNames() throws {
    let data = try JSONEncoder().encode(starting)
    let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(Set(object.keys) == ["stops", "intensity", "grain", "texture", "translucency", "mode"])
    let json = #"{"stops":[{"color":{"r":1,"g":0,"b":0,"a":1},"x":0.5,"y":0.5}],"intensity":0.6,"grain":0,"texture":"sand","translucency":1,"mode":"dark","angle":45,"dark":{"stops":[],"intensity":1,"grain":0,"texture":"grain","translucency":0}}"#
    let decoded = try JSONDecoder().decode(ProfileThemeValue.self, from: Data(json.utf8))
    #expect(decoded.texture == .sand && decoded.mode == .dark && decoded.angle == 45 && decoded.dark?.intensity == 1)
  }
}
