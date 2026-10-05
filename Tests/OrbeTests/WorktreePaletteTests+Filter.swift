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
    XCTAssertEqual(p.visibleSections.map(\.title), [.branches], "マッチの無い worktree の欄は消える")
    XCTAssertEqual(p.items.map(\.name), ["origin/feat/fetch-progress"])
    XCTAssertEqual(p.selected, 0, "選択は一致した先頭の行")
  }

  /// worktree の行はブランチ名でも引ける（行にはパスだけを出す）。
  func testFilterMatchesWorktreeByItsBranch() {
    let p = makeModel()
    p.query = "issue/212"
    p.onQueryChanged()
    XCTAssertEqual(p.items.map(\.name), ["issue-212"])
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
      p.items.map(\.name), ["feat/arrived-later", "origin/feat/fetch-progress"],
      "新しく着いた行にもフィルタが効く")
  }

  func testFilterMatchesDetail() {
    let p = makeModel()
    p.query = "taro"
    p.onQueryChanged()
    XCTAssertEqual(p.items.count, 1, "補足（作者・相対日時）にもマッチ")
    XCTAssertEqual(p.selectedItem?.name, "origin/feat/fetch-progress")
  }

  /// 既存の行が 1 つも合わなければ、見出しと「一致する worktree・ブランチはありません」を出す。
  func testNoMatchShowsTheNote() {
    let p = makeModel()
    p.query = "zzz"
    p.onQueryChanged()
    XCTAssertTrue(p.items.isEmpty)
    XCTAssertEqual(p.visibleSections.map(\.title), [.worktreesAndBranches])
    XCTAssertEqual(p.visibleSections.first?.emptyNote, .worktreePaletteNoMatch)
  }
}
