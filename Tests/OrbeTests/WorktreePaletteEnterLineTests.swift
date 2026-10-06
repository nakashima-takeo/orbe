import XCTest

@testable import Orbe

/// worktree パレットのフッターとベースのバーが言う「↵ で何が起きるか」の組み立て。語順は言語ごとの
/// テンプレート（`%N$@`）が持ち、差し込む値は画面が渡す。壊れると、名前と起動先が入れ替わって出る・
/// `%3$@` がそのまま画面に出る・ある言語でだけ値が欠ける、のどれかになり、↵ の説明が嘘になる。
final class WorktreePaletteEnterLineTests: OrbeTestCase {

  /// 差し込み位置はテンプレートに書かれた順に並び、間の語はそのまま残る。
  func testSegmentsFollowTheTemplateOrder() {
    XCTAssertEqual(
      PaletteActionLine.segments("%1$@ を %3$@ から作り、%2$@ で開く", count: 3),
      [
        .slot(0), .literal(" を "), .slot(2), .literal(" から作り、"), .slot(1), .literal(" で開く"),
      ])
  }

  /// 渡した値より後ろの位置は、値を作らずに書かれたまま残す（落ちずに読める形で出る）。
  func testPositionBeyondTheValuesStaysAsWritten() {
    XCTAssertEqual(
      PaletteActionLine.segments("%1$@ と %2$@", count: 1),
      [.slot(0), .literal(" と "), .literal("%2$@")])
  }

  /// ↵ の説明（タスクに起こすことの続きを含む）と「なし — …」のテンプレートは、どの言語でも画面が渡す値を
  /// ちょうど 1 回ずつ使う。
  func testEveryTemplateUsesEachValueOnceInEveryLanguage() {
    let valueCounts: [(L10nKey, Int)] = [
      (.worktreePaletteEnterOpen, 2),
      (.worktreePaletteEnterCheckout, 2),
      (.worktreePaletteEnterCreate, 3),
      (.worktreePaletteEnterPickBase, 0),
      (.worktreePaletteEnterClean, 0),
      (.worktreePaletteBaseNoneWorktree, 0),
      (.worktreePaletteBaseNoneDirectory, 0),
      (.worktreePaletteBaseNoneCheckout, 1),
      (.worktreePaletteBaseNoneTrackRemote, 2),
      (.worktreePaletteBaseNoneClean, 0),
      (.worktreePaletteBasePickEnter, 1),
      (.worktreePaletteBaseNonePullRequest, 2),
      (.worktreePaletteEffectBegin, 1),
      (.worktreePaletteEffectBeginReassign, 2),
      (.worktreePaletteEffectReassign, 2),
    ]
    for (key, count) in valueCounts {
      for language in Language.allCases {
        let segments = PaletteActionLine.segments(L10n.string(key, language), count: count)
        let slots = segments.compactMap { segment -> Int? in
          if case .slot(let index) = segment { return index }
          return nil
        }
        XCTAssertEqual(slots.sorted(), Array(0..<count), "\(key) \(language)")
        let literals = segments.compactMap { segment -> String? in
          if case .literal(let text) = segment { return text }
          return nil
        }
        XCTAssertFalse(literals.contains { $0.contains("%") }, "\(key) \(language) に未解決の位置が残る")
      }
    }
  }
}
