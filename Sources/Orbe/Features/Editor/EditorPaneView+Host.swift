import AppKit
import OrbeEditorCore

/// 面を載せる側の口（`TextSurfaceHost`）と、Finder のファイルのドロップ。開くこと・根・言語は pane の関心で、面は知らない。
/// 本文の上のドロップは面が受け（⇧ でパスを入れる・無ければここへ「開く」を渡す）、ツリー・タブ行・空状態の上は pane が
/// 受けて開く。
extension EditorPaneView: TextSurfaceHost {
  /// 開く（フォルダは開かない）。焦点は最後に開いた文書の面へ。
  func openFiles(_ urls: [URL]) {
    for url in urls where !Self.isDirectory(url) { open(url) }
  }

  /// 根からの相対パス（根の外なら絶対パス）を空白で区切ったもの（VS Code と同じ）。
  func insertionText(forFiles urls: [URL]) -> String {
    let root = URL(fileURLWithPath: tree.root).standardizedFileURL.path
    return urls.map { url in
      let path = url.standardizedFileURL.path
      return path.hasPrefix(root + "/") ? String(path.dropFirst(root.count + 1)) : path
    }.joined(separator: " ")
  }

  /// カット・コピー・ペースト（target を持たず焦点の面へ届く）。サービスは AppKit が開くときに足す。
  func contextMenu() -> NSMenu {
    let menu = NSMenu()
    let language = localization.language
    menu.addItem(
      withTitle: L10n.string(.menuCut, language), action: #selector(NSText.cut(_:)),
      keyEquivalent: "")
    menu.addItem(
      withTitle: L10n.string(.menuCopy, language), action: #selector(NSText.copy(_:)),
      keyEquivalent: "")
    menu.addItem(
      withTitle: L10n.string(.menuPaste, language), action: #selector(NSText.paste(_:)),
      keyEquivalent: "")
    return menu
  }

  func openLink(_ url: URL) {
    NSWorkspace.shared.open(url)
  }

  /// 本文で Esc（変換中でない）。検索バーがあれば閉じて使う（VS Code と同じく、カーソルを 1 本に戻すより先）。
  func consumeEscape() -> Bool {
    guard searchBar != nil else { return false }
    closeSearch()
    return true
  }

  // MARK: - ファイルのドロップ

  override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
    droppedFiles(sender).isEmpty ? [] : .copy
  }

  override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
    draggingEntered(sender)
  }

  override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
    let files = droppedFiles(sender)
    guard !files.isEmpty else { return false }
    openFiles(files)
    return true
  }

  /// 落とされた開けるファイル（フォルダを除く）。
  private func droppedFiles(_ info: NSDraggingInfo) -> [URL] {
    let urls =
      info.draggingPasteboard.readObjects(
        forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
    return urls.filter { !Self.isDirectory($0) }
  }

  private static func isDirectory(_ url: URL) -> Bool {
    (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
  }
}
