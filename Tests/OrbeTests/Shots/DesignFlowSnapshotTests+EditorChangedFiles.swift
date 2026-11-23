import OrbeTestSupport
import SwiftUI
import XCTest

@testable import Orbe

/// 左の列を閉じた Changes・PR の画面の、上のバーの今のファイルのボタンと変更ファイルの一覧の flow。一覧の器は面が窓に付いて
/// いる間だけ開いているので、面を付けた窓の中でそのまま描く（`renderInPlace`）。操作は製品と同じ入口（左の列の開閉・ボタンの
/// 閉包・行の列へのキー）から入れる。
extension DesignFlowSnapshotTests {
  /// Changes: 左の列を閉じる（ボタンが出る）→ 押す（2 区分の一覧。選択は本体の diff の行）→ ↓ → ↵（その diff が本体に出る）。
  func testEditorScmChangedFiles() throws {
    let queriesRoot = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
    let scene = try ScmFixtures.scene(queriesRoot: queriesRoot, in: TestScratch.caseDir)
    defer { scene.cleanup() }
    scene.warmUp()
    pumpMain(until: { scene.isReady }, "行・グラフ・HEAD の push 済みが揃う")
    let pane = scene.pane
    pumpMain(until: { Self.diffIsPlaced(pane) }, "本体に diff が出る")
    try renderInPlace(
      pane, name: "editor_scm_changed_files", dir: previewDir("flows"), appearances: [true, false],
      steps: changedFilesSteps(pane))
  }

  /// PR: README.md を確認済みにして、左の列を閉じる → 押す（確認済みの行は弱い色）→ ↓ → ↵。
  func testEditorPrChangedFiles() throws {
    let queriesRoot = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
    let scene = try PrFixtures.scene(queriesRoot: queriesRoot, in: TestScratch.caseDir)
    defer { scene.cleanup() }
    scene.warmUp()
    pumpMain(until: { scene.isReady }, "PR の中身と帯が揃う")
    scene.openDiff()
    pumpMain(until: { scene.isDiffReady }, "PR の diff が揃う")
    scene.panel.toggleViewed("README.md")
    let pane = scene.pane
    try renderInPlace(
      pane, name: "editor_pr_changed_files", dir: previewDir("flows"), appearances: [true, false],
      steps: changedFilesSteps(pane))
  }

  private func changedFilesSteps(_ pane: EditorPaneView) -> [(label: String, action: () -> Void)] {
    [
      (
        "sidebar_closed",
        {
          pane.toggleSidebar()
          pumpMain(until: { pane.shell.currentItem != nil }, "ボタンが出る")
        }
      ),
      ("list", { pane.shell.toggleItemList() }),
      ("down", { self.listKey(pane, Self.arrow(.downArrow)) }),
      (
        "enter",
        {
          self.listKey(pane, "\r")
          pumpMain(until: { Self.diffIsPlaced(pane) }, "選んだ diff が揃う")
        }
      ),
    ]
  }

  private static func diffIsPlaced(_ pane: EditorPaneView) -> Bool {
    guard let diff = pane.diff else { return false }
    if case .unavailable = diff.content { return true }
    return diff.content == .ready && diff.placement == .placed && !diff.pending
  }
}
