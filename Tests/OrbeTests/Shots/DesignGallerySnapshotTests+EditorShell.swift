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

  /// 上のバーの部品の姿（`editor_bar_parts`）と、3 つの画面の姿の並びを幅 1100・820・600 で（`editor_bar_<画面>`）。Files の
  /// 画面のファイル内検索の欄の姿（一致あり・仮の文書つき・一致なし・フォーカスなし・検索語が空）を幅 1100 で
  /// （`editor_bar_files_find`）。
  func renderEditorBarSnapshots(dir: URL) throws {
    try writePNG(
      EditorShellFixtures.barParts(), size: NSSize(width: 900, height: 240),
      name: "editor_bar_parts.png", dir: dir)
    let widths: [CGFloat] = [1100, 820, 600]
    for (screen, name) in [
      (EditorScreen.changes, "changes"), (.pullRequest, "pull_request"), (.files, "files"),
    ] {
      try writePNG(
        EditorShellFixtures.bars(screen, widths: widths), size: NSSize(width: 1100, height: 148),
        name: "editor_bar_\(name).png", dir: dir)
    }
    try writePNG(
      EditorShellFixtures.filesFindBars(), size: NSSize(width: 1100, height: 236),
      name: "editor_bar_files_find.png", dir: dir)
  }

  /// 上のバーの右下の置き場——ポップアップだけ（`editor_dock_popup`）・ポップアップと失敗の札 2 枚（`editor_dock_cards`）・
  /// 色つきの縁（`editor_dock_tinted`）・札だけ（`editor_dock_cards_only`）・高さが足りず、ポップアップが縮む姿
  /// （`editor_dock_short`。中身は 10 行）・中身が地の外にメニューを並べた姿（`editor_dock_menu`）。
  func renderEditorDockSnapshots(dir: URL) throws {
    let size = NSSize(width: 760, height: 420)
    let plain = EditorShellFixtures.DockPopupOwner(popup: nil)
    try writePNG(
      EditorShellFixtures.dock(owner: plain, cards: false, height: 300), size: size,
      name: "editor_dock_popup.png", dir: dir)
    try writePNG(
      EditorShellFixtures.dock(owner: plain, cards: true, height: 300), size: size,
      name: "editor_dock_cards.png", dir: dir)
    let tinted = EditorShellFixtures.DockPopupOwner(popup: nil, tint: Color.theme.success)
    try writePNG(
      EditorShellFixtures.dock(owner: tinted, cards: false, height: 300), size: size,
      name: "editor_dock_tinted.png", dir: dir)
    try writePNG(
      EditorShellFixtures.dock(owner: nil, cards: true, height: 300), size: size,
      name: "editor_dock_cards_only.png", dir: dir)
    let menu = EditorShellFixtures.DockPopupOwner(popup: nil)
    menu.showsMenu = true
    try writePNG(
      EditorShellFixtures.dock(owner: menu, cards: true, height: 300), size: size,
      name: "editor_dock_menu.png", dir: dir)
    let long = EditorShellFixtures.DockPopupOwner(popup: nil)
    long.field.string = (1...10).map { "行 \($0)" }.joined(separator: "\n")
    try writePNG(
      EditorShellFixtures.dock(owner: long, cards: true, height: 220), size: size,
      name: "editor_dock_short.png", dir: dir)
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
