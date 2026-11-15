import XCTest

@testable import OrbeEditorCore

/// 区間を見せる方針ごとの縦の着地（先頭行・小数）。ファイル内検索の一致（見えていなければ中央へ）・プロジェクト検索の結果
/// （中央へ）・キャレット（最小限）の着地がこの式で決まる。
final class TextRevealTests: XCTestCase {
  func testCenterPutsTheFirstRowInTheMiddleEvenWhenVisible() {
    XCTAssertEqual(TextReveal.center.firstLine(showing: 50..<51, first: 0, visible: 10), 45.5)
    XCTAssertEqual(
      TextReveal.center.firstLine(showing: 47..<48, first: 45, visible: 10), 42.5, "見えていても送る")
    XCTAssertEqual(
      TextReveal.center.firstLine(showing: 50..<71, first: 0, visible: 10), 50,
      "見えている高さより高い区間は先頭の行を上端へ")
  }

  /// 先頭の行が上へ少しでも隠れていれば外、下端で欠けて見えている行は中（最小限で全部を見せる）。
  func testCenterIfOutsideCentersOnlyWhenTheFirstRowIsOutside() {
    let policy = TextReveal.centerIfOutside
    XCTAssertEqual(policy.firstLine(showing: 50..<51, first: 45, visible: 10), 45, "見えていれば動かない")
    XCTAssertEqual(policy.firstLine(showing: 80..<81, first: 45, visible: 10), 75.5, "下の外は中央へ")
    XCTAssertEqual(policy.firstLine(showing: 50..<51, first: 50.25, visible: 10), 45.5, "上へ欠けた行は外")
    XCTAssertEqual(
      policy.firstLine(showing: 54..<55, first: 45, visible: 9.5), 45.5, "下端で欠けた行は中——最小限で見せる")
  }

  func testMinimalMovesOnlyAsFarAsNeeded() {
    let policy = TextReveal.minimal
    XCTAssertEqual(policy.firstLine(showing: 12..<14, first: 10, visible: 10), 10, "見えていれば動かない")
    XCTAssertEqual(policy.firstLine(showing: 5..<6, first: 10, visible: 10), 5, "上の外は上端へ")
    XCTAssertEqual(policy.firstLine(showing: 30..<32, first: 10, visible: 10), 22, "下の外は下端へ")
    XCTAssertEqual(policy.firstLine(showing: 30..<51, first: 10, visible: 10), 30, "高い区間は先頭を上端へ")
  }
}
