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
}
