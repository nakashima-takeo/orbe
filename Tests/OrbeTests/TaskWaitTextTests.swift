import XCTest

@testable import Orbe

/// 解けた待ちの「起きたこと」の文字（行・詳細・メニューバーのピルが同じ関数で引く）。
///
/// 壊れると何が起きるか: 何も出力しない確認のコマンドで解けたタスクの行とピルが、起きたことの欄だけ空になる。
final class TaskWaitTextTests: OrbeTestCase {
  private let l10n = LocalizationStore(language: .ja)

  private func headline(_ how: WaitResolution.How) -> String {
    let resolution = WaitResolution(
      waiting: TaskItem.Waiting(reason: "レビュー待ち", since: Date()), how: how, at: Date())
    return TaskWaitText.headline(resolution.headline, l10n: l10n)
  }

  /// 確認の出力が空（空白と改行だけも含む）なら「条件を満たした」。
  func testEmptyOutputReadsAsConditionMet() {
    XCTAssertEqual(headline(.satisfied(output: "")), "条件を満たした")
    XCTAssertEqual(headline(.satisfied(output: "  \n\t\n")), "条件を満たした")
  }

  func testOutputAndDeadlineReadAsWhatHappened() {
    XCTAssertEqual(headline(.satisfied(output: "\nレビューが付いた\n@sato")), "レビューが付いた")
    XCTAssertEqual(headline(.expired), "期限が来た")
  }
}
