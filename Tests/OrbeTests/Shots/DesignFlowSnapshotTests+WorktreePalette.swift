import SwiftUI
import XCTest

@testable import Orbe

/// worktree パレットの新しいブランチの flow（ファイル分割の拡張）。撮り方・出力先は本体の `flow` を共有する。
extension DesignFlowSnapshotTests {
  /// 新しいブランチのベース: 作成行で ⇧⇥ がベースを巡回し、「ほか…」の ↵ でベースを選ぶ画面へ入り、
  /// 絞り込んで決めると「ほか…」の直前に選んだ名前が出て選ばれる、までを撮る。
  func testNewBranchBase() throws {
    let palette = DesignSceneFixtures.worktreePaletteNewBranchModel()
    try flow(
      "new_branch_base", size: NSSize(width: 752, height: 520),
      render: {
        ZStack {
          BackgroundGlow()
          WorktreePaletteOverlay(model: palette)
        }
      },
      steps: [
        ("previous", {}),
        ("default", { palette.cycleBase() }),
        ("current", { palette.cycleBase() }),
        ("other", { palette.cycleBase() }),
        ("picker", { palette.submit() }),
        ("filter", { palette.basePicker?.query = "fetch" }),
        ("picked", { palette.submit() }),
      ])
  }
}

extension DesignFlowSnapshotTests {
  /// タスクから開いた ⌘T: 先頭の「＋ issue/221 を作る」（XTIssue）→ ⇧⇥ で既定のベース（XTIssueMain）→
  /// 別のタスク（#214）が持つ worktree の行でフッターが付け替えを言う → ⌫ で札を外すといつもの ⌘T
  /// （欄の組み直しは provider の代わりに同じ入力から組む）。
  func testTaskWorktree() throws {
    let palette = DesignSceneFixtures.worktreePaletteIssueModel()
    try flow(
      "task_worktree", size: NSSize(width: 752, height: 560),
      render: {
        ZStack {
          BackgroundGlow()
          WorktreePaletteOverlay(model: palette)
        }
      },
      steps: [
        ("issue", {}),
        ("default_base", { palette.cycleBase() }),
        ("reassign", { palette.move(2) }),
        (
          "removed",
          {
            palette.jump(-1)
            palette.clearTaskContext()
            palette.sections = WorktreePaletteSectionBuilder.build(.designSample)
            palette.restoreSelection(matching: nil)
          }
        ),
      ])
  }
}
