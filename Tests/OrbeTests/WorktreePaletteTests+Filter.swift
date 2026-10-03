import XCTest

@testable import Orbe

/// ヘッダ ❯ の絞り込み（全セクション横断のローカル照合）。壊れると、打った語に合う行が出ない・合わない行が
/// 残る、のどちらかになる。
@MainActor
extension WorktreePaletteTests {

  func testFilterNarrowsAcrossSectionsAndDropsEmpty() {
    let p = makeModel()
    p.query = "feat"
    p.onQueryChanged()
    XCTAssertEqual(
      p.visibleSections.map(\.title), ["Worktrees", "Remote branches"],
      "マッチの無い Local branches セクションは消える")
    XCTAssertEqual(p.items.count, 2, "feat を含む 2 行だけ残る")
    XCTAssertEqual(p.selected, 0, "選択は先頭の可視行へクランプ")
    XCTAssertEqual(p.selectedItem?.name, "agent-hooks")
  }

  /// 絞り込み中に裏の列挙の引き直しで行が差し替わっても、入力中のフィルタは新しい行に効いたまま。
  func testFilterStaysAppliedWhenSectionsAreReplaced() {
    let p = makeModel()
    p.query = "feat"
    p.onQueryChanged()
    var input = WorktreePaletteSectionBuilder.Input.designSample
    input.localBranches.append(
      GitBranch(name: "feat/arrived-later", relativeDate: "now", upstream: nil))
    input.localBranches.append(GitBranch(name: "unrelated", relativeDate: "now", upstream: nil))

    p.sections = WorktreePaletteSectionBuilder.build(input)

    XCTAssertEqual(
      p.visibleSections.first { $0.title == "Local branches" }?.items.map(\.name),
      ["feat/arrived-later"], "新しく着いた行にもフィルタが効く")
    XCTAssertEqual(p.items.count, 3, "既存の feat 2 行＋新しく着いた 1 行")
  }

  func testFilterMatchesDetail() {
    let p = makeModel()
    p.query = "taro"
    p.onQueryChanged()
    XCTAssertEqual(p.items.count, 1, "補足（作者・相対日時）にもマッチ")
    XCTAssertEqual(p.selectedItem?.name, "origin/feat/session-restore")
  }
}
