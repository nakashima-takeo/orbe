import XCTest

@testable import OrbeEditorCore

/// 区間を見せる方針ごとの縦の着地（先頭行・小数）。ファイル内検索の一致（見えていなければ中央へ）・プロジェクト検索の結果
/// （中央へ）・アウトラインのシンボル（見えていなければ上寄りに）・キャレット（最小限）の着地がこの式で決まる。
final class TextRevealTests: XCTestCase {
  func testCenterPutsTheFirstRowInTheMiddleEvenWhenVisible() {
    XCTAssertEqual(TextReveal.center.firstLine(showing: 50...50, first: 0, visible: 10), 45.5)
    XCTAssertEqual(
      TextReveal.center.firstLine(showing: 47...47, first: 45, visible: 10), 42.5, "見えていても送る")
    XCTAssertEqual(
      TextReveal.center.firstLine(showing: 50...70, first: 0, visible: 10), 50,
      "見えている高さより高い区間は先頭の行を上端へ")
  }

  /// 先頭の行が上へ少しでも隠れていれば外、下端で欠けて見えている行は中（最小限で全部を見せる）。
  func testCenterIfOutsideCentersOnlyWhenTheFirstRowIsOutside() {
    let policy = TextReveal.centerIfOutside
    XCTAssertEqual(policy.firstLine(showing: 50...50, first: 45, visible: 10), 45, "見えていれば動かない")
    XCTAssertEqual(policy.firstLine(showing: 80...80, first: 45, visible: 10), 75.5, "下の外は中央へ")
    XCTAssertEqual(policy.firstLine(showing: 50...50, first: 50.25, visible: 10), 45.5, "上へ欠けた行は外")
    XCTAssertEqual(
      policy.firstLine(showing: 54...54, first: 45, visible: 9.5), 45.5, "下端で欠けた行は中——最小限で見せる")
  }

  /// 見えていなければ先頭の行を上から max(5 行, 高さの 20%) 下へ。区間の終わりが下へ押し出されるならそれを見せる位置、
  /// 区間が高さより高ければ先頭を上端へ。見えていれば動かない（VS Code の revealRangeNearTopIfOutsideViewport）。
  func testNearTopIfOutsideLeavesAGapAboveTheRange() {
    let policy = TextReveal.nearTopIfOutside
    XCTAssertEqual(policy.firstLine(showing: 100...102, first: 0, visible: 20), 95, "5 行の間")
    XCTAssertEqual(policy.firstLine(showing: 200...201, first: 0, visible: 50), 190, "高さの 20%")
    XCTAssertEqual(policy.firstLine(showing: 100...115, first: 0, visible: 20), 96, "終わりを押し出さない")
    XCTAssertEqual(policy.firstLine(showing: 10...40, first: 0, visible: 20), 10, "高さより高い区間は先頭を上端へ")
    XCTAssertEqual(policy.firstLine(showing: 5...6, first: 0, visible: 20), 0, "見えていれば動かない")
    XCTAssertEqual(policy.firstLine(showing: 30...31, first: 40, visible: 20), 25, "上の外も同じ")
  }

  func testMinimalMovesOnlyAsFarAsNeeded() {
    let policy = TextReveal.minimal
    XCTAssertEqual(policy.firstLine(showing: 12...13, first: 10, visible: 10), 10, "見えていれば動かない")
    XCTAssertEqual(policy.firstLine(showing: 5...5, first: 10, visible: 10), 5, "上の外は上端へ")
    XCTAssertEqual(policy.firstLine(showing: 30...31, first: 10, visible: 10), 22, "下の外は下端へ")
    XCTAssertEqual(policy.firstLine(showing: 30...50, first: 10, visible: 10), 30, "高い区間は先頭を上端へ")
  }
}
