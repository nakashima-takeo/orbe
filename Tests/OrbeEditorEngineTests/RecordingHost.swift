import AppKit
import OrbeEditorCore

/// 面を載せる側の偽物。面が問うたことを記録する（面は弱く持つので、テストが持っておく）。
@MainActor
final class RecordingHost: TextSurfaceHost {
  private(set) var openedFiles: [[URL]] = []
  private(set) var links: [URL] = []
  private(set) var menus = 0

  func openFiles(_ urls: [URL]) { openedFiles.append(urls) }

  /// ファイル名を空白で区切ったもの。
  func insertionText(forFiles urls: [URL]) -> String {
    urls.map(\.lastPathComponent).joined(separator: " ")
  }

  func contextMenu() -> NSMenu {
    menus += 1
    let menu = NSMenu()
    menu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "")
    return menu
  }

  func openLink(_ url: URL) { links.append(url) }
}
