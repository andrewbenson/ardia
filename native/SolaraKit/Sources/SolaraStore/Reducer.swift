import SolaraModel

public enum Reducer {
  public static func apply(_ command: Command, to tx: inout Transaction) throws {
    switch command {
    case .updateSettings(let patch, let fromSync):
      tx.state.settings = tx.state.settings.updated(patch, fromSync: fromSync)
    case .upsertDownload(let download, let privateSession, let focusedWindowShowing):
      Downloads.upsert(download, privateSession: privateSession, focusedWindowShowing: focusedWindowShowing, in: &tx)
    case .removeDownload(let id):
      tx.state.downloads.removeAll { $0.id == id }
    case .clearDownloads(let visibleIds):
      let visible = visibleIds.map(Set.init)
      tx.state.downloads.removeAll { download in
        !download.isDownloading && (visible.map { $0.contains(download.id) } ?? true)
      }
    case .forgetDownloads(let ids, let privateSession):
      let gone = Set(ids)
      if privateSession { tx.memory.endedPrivateDownloads.formUnion(gone) }
      tx.state.downloads.removeAll { gone.contains($0.id) }
    }
  }
}

enum Downloads {
  static func upsert(_ download: Download, privateSession: PrivateDownloadSession?, focusedWindowShowing: String?, in tx: inout Transaction) {
    let exists = tx.state.downloads.contains { $0.id == download.id }
    if !exists, let privateSession, !privateSession.open || tx.memory.endedPrivateDownloads.contains(download.id) {
      tx.memory.endedPrivateDownloads.insert(download.id)
      return
    }
    if exists {
      for i in tx.state.downloads.indices where tx.state.downloads[i].id == download.id { tx.state.downloads[i] = download }
    } else {
      tx.state.downloads.insert(download, at: 0)
      if tx.state.downloads.count > Download.maxKept { tx.state.downloads.removeLast(tx.state.downloads.count - Download.maxKept) }
      if let focusedWindowShowing { tx.effects.append(.openDownloads(windowId: focusedWindowShowing)) }
    }
  }
}

public enum Settle {
  public static func run(_ tx: inout Transaction) throws {}
}

public struct InvariantViolation: Error, CustomStringConvertible {
  public let description: String
}

public enum Invariants {
  public static func check(_ state: BrowserState) throws {
    var seen = Set<String>()
    for download in state.downloads where !seen.insert(download.id).inserted {
      throw InvariantViolation(description: "download \(download.id) is listed twice")
    }
  }
}
