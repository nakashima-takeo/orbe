import XCTest

@testable import Orbe

/// ホバー選択追従と入力モダリティ・ガードの検証。ガードは「選択を置いた側が意図を持っている間は
/// 実マウス移動があるまでホバーに奪わせない」で、`selected` への代入経路が増えても効き続ける必要がある。
@MainActor
final class PaletteModelHoverTests: XCTestCase {
  private func model() -> PaletteModel {
    let m = PaletteModel()
    m.rows = (0..<5).map { PaletteModel.RowItem(label: "row\($0)") }
    return m
  }

  /// 初期は `.keyboard`。開いた直後にカーソルがカード上にあってもホバーが初期選択を奪わない。
  func testHoverIsSuppressedBeforeAnyPointerMove() {
    let m = model()
    m.selected = 2
    m.hoverSelect(4)
    XCTAssertEqual(m.selected, 2)
  }

  /// 実マウス移動後（`.pointer`）はホバーが選択を追従させる。
  func testHoverFollowsAfterPointerMove() {
    let m = model()
    m.inputModality = .pointer
    m.hoverSelect(4)
    XCTAssertEqual(m.selected, 4)
  }

  /// ホバー追従はモダリティを維持し、続くホバーも効き続ける。
  func testHoverKeepsPointerModality() {
    let m = model()
    m.inputModality = .pointer
    m.hoverSelect(1)
    m.hoverSelect(3)
    XCTAssertEqual(m.selected, 3)
  }

  /// キー移動は `.keyboard` へ戻す。スクロールで行がカーソル下へ来ても選択を奪われない。
  func testKeyMoveRestoresKeyboardModality() {
    let m = model()
    m.inputModality = .pointer
    m.move(1)
    m.hoverSelect(4)
    XCTAssertEqual(m.selected, 1)
  }

  /// ホバー以外の代入（絞り込みでの先頭リセット・ドリルイン等、パレットモデルが直接置く経路）も
  /// `.keyboard` へ戻す。矢印移動だけを守ると、打鍵で行が入れ替わった瞬間に奪取が漏れる。
  func testModelDrivenSelectionRestoresKeyboardModality() {
    let m = model()
    m.inputModality = .pointer
    m.selected = 0  // 行集合の入れ替え時にパレットモデルが置く選択
    m.hoverSelect(4)
    XCTAssertEqual(m.selected, 0)
  }
}
