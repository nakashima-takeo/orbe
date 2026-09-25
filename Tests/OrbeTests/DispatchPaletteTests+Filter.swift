import XCTest

@testable import Orbe

/// ヘッダ ❯ の絞り込み（全セクション横断のローカル照合）。壊れると、打った語に合う行が出ない・合わない行が
/// 残る・取得中なのに「無い」と見分けがつかない、のどれかになる。
@MainActor
extension DispatchPaletteTests {

  func testFilterNarrowsAcrossSectionsAndDropsEmpty() {
    let p = makeModel()
    p.query = "feat"
    p.onQueryChanged()
    XCTAssertEqual(
      p.visibleSections.map(\.title), ["Worktrees", "Remote branches", "Pull requests"],
      "マッチの無い Local branches / Issues セクションは消える")
    XCTAssertEqual(p.items.count, 3, "feat を含む 3 行だけ残る")
    XCTAssertEqual(p.selected, 0, "選択は先頭の可視行へクランプ")
    XCTAssertEqual(p.selectedItem?.name, "agent-hooks")
  }

  /// 絞り込み中に裏の gh 更新で行が差し替わっても、入力中のフィルタは新しい行に効いたまま。
  func testFilterStaysAppliedWhenSectionsAreReplaced() {
    let p = makeModel()
    p.query = "feat"
    p.onQueryChanged()
    var input = DispatchSectionBuilder.Input.designSample
    input.issues.append(GitHubIssue(number: 999, title: "feat: arrived later"))
    input.issues.append(GitHubIssue(number: 998, title: "unrelated"))

    p.sections = DispatchSectionBuilder.build(input)

    XCTAssertEqual(
      p.visibleSections.first { $0.title == "Issues" }?.items.map(\.name),
      ["feat: arrived later"], "新しく着いた行にもフィルタが効く")
    XCTAssertEqual(p.items.count, 4, "既存の feat 3 行＋新しく着いた 1 行")
  }

  /// 取得が続いているセクションは、絞り込みでヒット 0 件でも見出しとローディング行を残す（「無い」と
  /// 「まだ届いていない」を見分けられる）。ローディング行は選択の対象にならない。
  func testFilterKeepsGrowingSectionWithZeroHits() {
    var input = DispatchSectionBuilder.Input.designSample
    input.issuesGrowing = true
    input.pullRequestsGrowing = true
    let p = makeModel(input)
    p.query = "feat"
    p.onQueryChanged()
    XCTAssertEqual(
      p.visibleSections.first { $0.title == "Issues" }?.items.map(\.isLoadingRow), [true],
      "ヒット 0 件でも取得中の印は残る")
    XCTAssertEqual(p.items.last?.isLoadingRow, true, "前提: 末尾は PR 側のローディング行")
    p.jump(1)
    XCTAssertEqual(p.selectedItem?.name, "feat: session restore", "ローディング行を飛ばして末尾の対話行へ")
  }

  func testFilterMatchesIdAndDetail() {
    let p = makeModel()
    p.query = "#145"
    p.onQueryChanged()
    XCTAssertEqual(p.items.count, 1, "idText の #145 に PR 行がマッチ")
    XCTAssertEqual(p.selectedItem?.name, "feat: session restore")
  }
}
