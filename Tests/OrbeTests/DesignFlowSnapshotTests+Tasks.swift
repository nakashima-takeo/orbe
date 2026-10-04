import SwiftUI
import XCTest

@testable import Orbe

/// タスク画面の flow（ファイル分割の拡張）。撮り方・出力先は本体の `flow` を共有する。
extension DesignFlowSnapshotTests {
  /// 打って絞り込み・↵ で追加・space で完了・→ で詳細・期限の編集（読めない入力は赤）・esc で一覧、
  /// agent が上の欄に足しても選択が動かない、までを撮る。
  func testTaskPalette() throws {
    let palette = DesignSceneFixtures.taskPaletteModel()
    try flow(
      "task_palette", size: NSSize(width: 1440, height: 900),
      render: {
        ZStack {
          BackgroundGlow()
          TaskPaletteOverlay(model: palette)
        }
        .environment(\.localization, LocalizationStore(language: .ja))
      },
      steps: [
        ("start", {}),
        ("typed", { palette.query = "PR の説明を書く" }),
        ("added", { palette.submit() }),
        ("done", { palette.toggleDone(palette.store.tasks.last!.id) }),
        (
          "detail",
          {
            palette.move(-1); palette.enterDetail()
          }
        ),
        (
          "due_field",
          {
            palette.moveField(1); palette.moveField(1); palette.moveField(1)
          }
        ),
        (
          "due_editing",
          {
            palette.beginEditing(); palette.draftText = "あした"
          }
        ),
        ("due_invalid", { palette.endEditing(commit: true) }),
        (
          "due_set",
          {
            palette.draftText = "10/9"; palette.endEditing(commit: true)
          }
        ),
        ("back", { palette.leaveDetail() }),
        (
          "agent_inserted",
          {
            let item = try? palette.store.add(TaskDraft(title: "agent が足した", status: .inProgress))
            if let item { try? palette.store.move(item.id, .before, 1) }
            palette.reconcile()
          }
        ),
      ])
  }

  /// 詳細の Issue・PR の欄: 行に入る・⌫ で外すと焦点が同じ位置へ移る・agent が結び付けると番号だけで
  /// 現れる（値はまだ届いていない）、までを撮る。
  func testTaskPaletteLinks() throws {
    let palette = DesignSceneFixtures.taskPaletteModel()
    try flow(
      "task_palette_links", size: NSSize(width: 1440, height: 900),
      render: {
        ZStack {
          BackgroundGlow()
          TaskPaletteOverlay(model: palette)
        }
        .environment(\.localization, LocalizationStore(language: .ja))
      },
      steps: [
        ("start", {}),
        (
          "link_focused",
          {
            palette.enterDetail(); palette.moveField(-1); palette.moveField(-1)
          }
        ),
        ("unlinked", { palette.unlink(palette.selectedTask!.links[0].item) }),
        (
          "agent_linked",
          {
            var update = TaskUpdate()
            update.links =
              palette.selectedTask!.links + [DesignSceneFixtures.taskLink(.issue, "orbe", 230)]
            _ = try? palette.store.update(1, update)
            palette.reconcile()
          }
        ),
      ])
  }

  /// 選んだ未完了の行の取っ手・掴んで下へ動かした途中（行のずれと落ちる位置の線）・欄の端で止まる掴んだ
  /// 行・離して並びが変わった後、を撮る。
  func testTaskPaletteDrag() throws {
    let palette = DesignSceneFixtures.taskPaletteModel()
    let height = TaskPaletteRowMetrics.height
    let start = CGPoint(x: 200, y: 300)
    try flow(
      "task_palette_drag", size: NSSize(width: 1440, height: 900),
      render: {
        ZStack {
          BackgroundGlow()
          TaskPaletteOverlay(model: palette)
        }
        .environment(\.localization, LocalizationStore(language: .ja))
      },
      steps: [
        ("grip", {}),
        ("grabbed_down", { palette.dragChanged(6, start: start, translation: height * 2.4) }),
        ("grabbed_up_edge", { palette.dragChanged(6, start: start, translation: -height * 5) }),
        ("dropped", { palette.dragEnded() }),
      ])
  }

  /// GitHub タブ: #221 をタスクにする（行が結び付いた側へ移る）・⌘L で別のタスクへ付け替えを選ぶ・↵ で付け替え・
  /// ⌘⌫ で外す（結び付いていない側へ戻る）、までを撮る。アサインの書き込みは何もしない置き場に頼む。
  func testTaskPaletteGithub() throws {
    let palette = DesignSceneFixtures.taskPaletteModel()
    let issue221 = TaskPaletteGitHubRowID.item(GitHubItemID(repo: "nakatake/orbe", number: 221)!)
    try flow(
      "task_palette_github", size: NSSize(width: 1440, height: 900),
      render: {
        ZStack {
          BackgroundGlow()
          TaskPaletteOverlay(model: palette)
        }
        .environment(\.localization, LocalizationStore(language: .ja))
      },
      steps: [
        (
          "start",
          {
            palette.toggleTab(); palette.tapGitHubRow(issue221)
          }
        ),
        (
          "pane_priority",
          {
            palette.enterPane(); palette.movePaneStop(1); palette.changePaneValue(-1)
          }
        ),
        ("made_task", { palette.submit() }),
        ("pick_task", { palette.linkSelectedGitHubItem() }),
        ("pick_moved", { palette.move(1) }),
        ("relinked", { palette.submit() }),
        ("unlinked", { palette.unlinkSelectedGitHubItem() }),
      ])
  }
}
