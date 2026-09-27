import Foundation
import XCTest

@testable import OrbeEditorCore

/// 位置を版の間で写す純関数。
///
/// 壊れると何が起きるか。取り直す前のアウトラインで、飛び先が名前の途中や隣の行にずれる。関数の本体を 1 字直しただけで、
/// その関数がカーソル追従で見つからなくなる。
final class OutlinePositionTests: XCTestCase {
  private func edit(_ location: Int, _ length: Int, _ replacement: String) -> TextEdit {
    TextEdit(range: NSRange(location: location, length: length), replacement: replacement)
  }

  /// 前へ: 編集より前はそのまま、後ろは平行移動、置き換えた区間の中（両端を含む）は寄せる側へ。
  func testMappingForwardShiftsAndClampsIntoTheBias() {
    let insert = edit(10, 0, "xyz")
    XCTAssertEqual(insert.map(9, bias: .after), 9)
    XCTAssertEqual(insert.map(10, bias: .before), 10, "挿入の位置の終わりは前に残る")
    XCTAssertEqual(insert.map(10, bias: .after), 13, "挿入の位置の頭は後ろへ")
    XCTAssertEqual(insert.map(11, bias: .after), 14)
    let replace = edit(10, 5, "ab")
    XCTAssertEqual(replace.map(12, bias: .before), 10)
    XCTAssertEqual(replace.map(12, bias: .after), 12)
    XCTAssertEqual(replace.map(20, bias: .after), 17)
  }

  /// 後ろへ: 置き換えた字の中の位置は編集の頭へ、後ろは平行移動して戻る。
  func testMappingBackReturnsInsertedPositionsToTheirHead() {
    let insert = edit(10, 0, "xyz")
    XCTAssertEqual(insert.unmap(9), 9)
    XCTAssertEqual(insert.unmap(11), 10)
    XCTAssertEqual(insert.unmap(13), 10)
    XCTAssertEqual(insert.unmap(14), 11)
    XCTAssertEqual(edit(10, 5, "ab").unmap(12), 15, "置き換えた字の直後は、置き換えた区間の後ろへ戻る")
    XCTAssertEqual(edit(10, 3, "").unmap(10), 13, "消した所の位置は、消した区間の後ろへ戻る")
  }

  /// 記録は何回ぶんの編集でも順に（戻すときは逆順に）写し、捨てた版からは写せない。
  func testTheLogMapsAcrossSeveralEditsAndNotFromDiscardedVersions() {
    var log = EditLog()
    let origin = TextPoint(row: 0, column: 0)
    _ = log.append(edit(0, 0, "ab"), start: origin, oldEnd: origin, newEnd: origin)
    _ = log.append(edit(10, 3, ""), start: origin, oldEnd: origin, newEnd: origin)
    XCTAssertEqual(log.map(20, from: 0, bias: .after), 19)
    XCTAssertEqual(log.unmap(19, to: 0), 20)
    XCTAssertEqual(log.map(5, from: 1, bias: .after), 5)
    log.discard(through: 1)
    XCTAssertNil(log.map(20, from: 0, bias: .after))
    XCTAssertEqual(log.map(12, from: 1, bias: .after), 10)
  }
}
