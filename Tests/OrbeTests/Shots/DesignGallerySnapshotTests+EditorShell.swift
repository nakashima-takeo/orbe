import OrbeTestSupport
import SwiftUI
import XCTest

@testable import Orbe

/// 骨込みのエディター面の gallery。広い幅（左の列 263）と狭い幅 360（左の列の表示幅が本体の最低幅 160 を残す 199 まで切り詰まり、
/// 上のバーから「⌥ 端末を表示」が消える）。status は git の子プロセス後に届くので、撮る前に揃うまで待つ。
extension DesignGallerySnapshotTests {
  func renderEditorShellSnapshots(dir: URL) throws {
    let queriesRoot = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
    let scene = try EditorShellFixtures.scene(queriesRoot: queriesRoot, in: TestScratch.caseDir)
    defer { scene.cleanup() }
    scene.warmUp()
    pumpMain(until: { scene.isReady }, "git バッジが揃う")
    try writePNG(
      scene.view, size: NSSize(width: 1100, height: 640), name: "editor_shell.png", dir: dir)
    try writePNG(
      scene.view, size: NSSize(width: 360, height: 480), name: "editor_shell_narrow.png", dir: dir)
  }

  /// 開いているファイルの一覧（今の文書・仮の文書・未保存・ディスクが変わった・状態の字あり／なしの行）と、その詳細（仮の
  /// 文書・普通の文書）、上のバーのボタン（仮の文書——キーの札 ↵ が無い姿（本文・検索の入力欄）とある姿（検索結果の列）・
  /// 未保存・ディスクが変わった）。
  func renderEditorShellOpenFilesSnapshots(dir: URL) throws {
    let scene = try openFilesScene(size: NSSize(width: 1100, height: 640))
    defer { scene.cleanup() }
    let pane = scene.pane
    let session = scene.group.editor
    func activate(_ name: String) {
      if let document = session.documents.first(where: { $0.url.lastPathComponent == name }) {
        session.activate(document.url)
      }
    }
    try renderInPlace(
      pane, name: "editor_shell_open_files", dir: dir, appearances: [true, false],
      steps: [
        ("list", { pane.shell.toggleItemList() }),
        ("detail_preview", { self.listKey(pane, Self.arrow(.rightArrow)) }),
        (
          "detail_file",
          {
            self.listKey(pane, Self.arrow(.leftArrow))
            self.listKey(pane, Self.arrow(.downArrow))
            self.listKey(pane, Self.arrow(.rightArrow))
          }
        ),
        (
          "bar_preview",
          {
            self.listKey(pane, "\u{1b}"); activate("tokens.json")
          }
        ),
        ("bar_preview_search_field", { pane.showProjectSearch(seed: nil) }),
        ("bar_preview_key", { pane.window?.makeFirstResponder(pane.searchResults.list) }),
        (
          "bar_unsaved",
          {
            pane.filesPanel = .files; activate("notes.txt")
          }
        ),
        ("bar_disk_changed", { activate("README.md") }),
      ])
  }
}
