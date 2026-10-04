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

  /// 載せる側が使う Esc の数（テストが置く）。使えば数を減らし、受けた数を数える。
  var escapesToConsume = 0
  private(set) var escapes = 0

  func consumeEscape() -> Bool {
    escapes += 1
    guard escapesToConsume > 0 else { return false }
    escapesToConsume -= 1
    return true
  }
}
