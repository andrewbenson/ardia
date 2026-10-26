import SwiftUI

enum PreviewGallery {
  static let framePoints = [0.2, 0.4, 0.65, 1]
  static let framesPerPage = 4
  static let frame = CGSize(width: 186, height: 130)
  static let plum = "#C07A98"
  static let dia = MockSettings(tabLayout: "sidebar", addressBar: "toolbar", appearance: "light", extendWebsiteColor: true)
  static let arc = MockSettings(tabLayout: "sidebar", addressBar: "sidebar", appearance: "dark", extendWebsiteColor: true)

  struct MockState {
    let label: String
    let settings: MockSettings
    let accent: String
    let focus: PreviewId?
  }

  static let mockPages: [[MockState]] = [
    [
      MockState(label: "Dia preset, light, plum", settings: dia, accent: plum, focus: nil),
      MockState(label: "Arc preset, dark, blue", settings: arc, accent: "#4691C3", focus: nil),
      MockState(label: "Auto appearance, top tabs, green", settings: MockSettings(tabLayout: "top", appearance: "auto", extendWebsiteColor: true), accent: "#3EB489", focus: nil),
      MockState(label: "Website color off, orange", settings: MockSettings(tabLayout: "sidebar", addressBar: "toolbar", appearance: "light", extendWebsiteColor: false), accent: "#D87249", focus: nil),
    ],
    [
      MockState(label: "⌘L field, sidebar address", settings: MockSettings(tabLayout: "sidebar", addressBar: "sidebar", appearance: "light", extendWebsiteColor: true), accent: plum, focus: .cmdlField),
      MockState(label: "⌘L field, toolbar address, dark", settings: MockSettings(tabLayout: "sidebar", addressBar: "toolbar", appearance: "dark", extendWebsiteColor: true), accent: "#4691C3", focus: .cmdlField),
      MockState(label: "⌘L centered", settings: dia, accent: "#7873AF", focus: .cmdlCentred),
      MockState(label: "Website color on", settings: dia, accent: plum, focus: .sitecolorOn),
    ],
  ]

  static var framePages: Int { (PreviewId.allCases.count + framesPerPage - 1) / framesPerPage }
}

struct PreviewGalleryCaption: View {
  @Environment(\.colorScheme) private var scheme
  let text: String

  var body: some View {
    Text(text).font(.system(size: 10.5, weight: .medium)).foregroundStyle(OnboardingColors.of(scheme).subtitle).lineLimit(1).frame(height: 14)
  }
}

struct PreviewGalleryFrames: View {
  @Environment(\.colorScheme) private var scheme
  let index: Int
  var addressInSidebar = false

  var body: some View {
    let dark = scheme == .dark
    let opts = SceneOpts(addressInSidebar: addressInSidebar, systemDark: dark, accent: PreviewGallery.plum)
    let ids = Array(PreviewId.allCases.dropFirst(index * PreviewGallery.framesPerPage).prefix(PreviewGallery.framesPerPage))
    let g = KitGeo(width: PreviewGallery.frame.width, height: PreviewGallery.frame.height)
    VStack(alignment: .leading, spacing: 6) {
      ForEach(ids, id: \.self) { id in
        let duration = Demo.duration(id)
        VStack(alignment: .leading, spacing: 2) {
          PreviewGalleryCaption(text: "\(id.rawValue) · \(Int(duration)) ms · \(PreviewGallery.framePoints.map { String(Int(PreviewColor.jsRound($0 * duration))) }.joined(separator: " / ")) ms\(addressInSidebar ? " · sidebar address" : "")")
          HStack(spacing: 8) {
            ForEach(PreviewGallery.framePoints, id: \.self) { f in
              DemoScene(id: id, g: g, look: PreviewLook.of(dark: dark, accent: PreviewGallery.plum), ms: f * duration, opts: opts)
                .frame(width: PreviewGallery.frame.width, height: PreviewGallery.frame.height)
                .clipShape(RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(PreviewColor.color(dark ? "#FFFFFF33" : "#00000026"), lineWidth: 0.5))
            }
          }
        }
      }
    }
  }
}

struct PreviewGalleryMocks: View {
  let index: Int

  var body: some View {
    let states = PreviewGallery.mockPages.indices.contains(index) ? PreviewGallery.mockPages[index] : []
    LazyVGrid(columns: [GridItem(.fixed(380), spacing: 16), GridItem(.fixed(380), spacing: 16)], alignment: .leading, spacing: 6) {
      ForEach(states, id: \.label) { state in
        VStack(alignment: .leading, spacing: 2) {
          PreviewGalleryCaption(text: state.label)
          MockWindow(settings: state.settings, accent: state.accent, focus: state.focus).frame(width: 380, height: 272)
        }
      }
    }
    .frame(width: 2 * 380 + 16, alignment: .leading)
  }
}

struct PreviewGalleryPage: View {
  @Environment(\.colorScheme) private var scheme
  enum Page {
    case frames(Int, addressInSidebar: Bool)
    case mocks(Int)
  }

  let page: Page

  var body: some View {
    Group {
      switch page {
      case .frames(let index, let field): PreviewGalleryFrames(index: index, addressInSidebar: field)
      case .mocks(let index): PreviewGalleryMocks(index: index)
      }
    }
    .padding(.top, 30)
    .padding(.horizontal, 18)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .background(OnboardingColors.of(scheme).card)
  }
}
