import XCTest

@testable import Orbe

/// 親「ソース管理」とグラフの枠の高さの割り振り——両方開いていれば持っている高さを、親に列より上のもの＋3 行を残す上限で
/// 丸める（持っている高さは変えない）。親を畳めばグラフの枠が残りを全部、グラフを畳めば見出しだけ。境目を引いた高さは上限と
/// 下限で止め、動かせないとき・見えている高さが変わらないときは持っている高さに触れない。
///
/// 壊れると何が起きるか。メッセージ欄が伸びて縮むたびに引いた高さが失われる。低い窓でグラフの枠が親を押し潰し、欄と変更の
/// 列が見えなくなる。親を畳んでもグラフが伸びず空きが残る。上限に押し付けた引き方で、記憶の高さが見えない値まで伸びる。
final class ScmPanelSplitTests: OrbeTestCase {
  private func split(
    total: CGFloat = 600, above: CGFloat = 100, stored: CGFloat = 198, repository: Bool = true,
    graph: Bool = true
  ) -> ScmPanelSplit {
    ScmPanelSplit(
      total: total, above: above, stored: stored, isRepositoryOpen: repository, isGraphOpen: graph)
  }

  func testBothOpenKeepTheStoredHeightUnderTheCeiling() {
    XCTAssertEqual(split().graphHeight, 198)
    XCTAssertEqual(split(above: 400).graphHeight, 600 - 400 - 66, "欄が伸びれば、親に列より上のもの＋3 行を残して縮む")
    XCTAssertEqual(split(total: 120).graphHeight, 22, "両立しなければ下限を割って見出しだけ残す")
  }

  func testClosingOneSideGivesTheRestToTheOther() {
    XCTAssertEqual(split(repository: false).graphHeight, 500, "親を畳めば残りを全部")
    XCTAssertEqual(split(graph: false).graphHeight, 22, "グラフを畳めば見出しだけ")
    XCTAssertEqual(split(repository: false, graph: false).graphHeight, 22)
  }

  func testDraggingStopsAtTheBoundsAndLeavesTheStoredHeightWhenNothingMoves() {
    XCTAssertEqual(split().dragged(to: 260), 260)
    XCTAssertEqual(split().dragged(to: 40), 88, "下限")
    XCTAssertEqual(split().dragged(to: 900), 434, "上限")
    XCTAssertNil(split(stored: 434).dragged(to: 900), "上限に押し付けても見えている高さが変わらなければ触れない")
    XCTAssertNil(split(total: 200).dragged(to: 260), "上限が下限に届かなければ動かせない")
  }
}
