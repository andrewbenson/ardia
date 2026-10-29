import SolaraEngine
import Testing
@testable import SolaraUI

@MainActor
struct BookmarkCatalogPageTests {
  @Test func pageReadsTreeAndKeepsSelectionOnlyForLiveNodes() {
    let model = BookmarksPageModel()
    let roots = BookmarkRoots(bar: "bar@default", other: "other@default")
    let bar = BookmarkNode(id: roots.bar, kind: "folder", parentId: nil, title: "Bookmarks Bar", children: ["a"])
    let other = BookmarkNode(id: roots.other, kind: "folder", parentId: nil, title: "Other Bookmarks", children: [])
    let link = BookmarkNode(id: "a", kind: "url", parentId: roots.bar, title: "A", url: "https://a.example/")
    model.bookmarkIcons = ["a": "data:image/png;base64,a"]
    model.apply(snapshot: BookmarkSnapshot(roots: roots, nodes: [bar.id: bar, other.id: other, link.id: link], ready: false))
    #expect(model.nodes.isEmpty)
    model.apply(snapshot: BookmarkSnapshot(roots: roots, nodes: [bar.id: bar, other.id: other, link.id: link], ready: true, revision: 1))
    #expect(model.folderId == roots.bar)
    #expect(model.ids == ["a"])
    #expect(model.nodes["a"]?.url == "https://a.example/")
    #expect(model.nodes["a"]?.favicon == "data:image/png;base64,a")
    model.selected = ["a"]
    model.apply(snapshot: BookmarkSnapshot(roots: roots, nodes: [bar.id: BookmarkNode(id: bar.id, kind: "folder", parentId: nil, title: bar.title, children: []), other.id: other], ready: true, revision: 2))
    #expect(model.selected.isEmpty)
    #expect(model.ids.isEmpty)
  }
}
