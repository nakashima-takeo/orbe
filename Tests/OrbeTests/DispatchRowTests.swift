import SwiftUI
import XCTest

@testable import Orbe

/// Dispatch の行（`DispatchRow`）の幅の契約。
///
/// リストは行を個別に測るので、行が割り当て幅を越えると、その行だけがカードからはみ出して「開く」の
/// 位置がそろわなくなる。縮みきった文字が 1 文字だけの欠片で残ると、「…」の無い読めない字が出る。
@MainActor
final class DispatchRowTests: OrbeTestCase {

  /// 提案幅 `width` を与えたときにレイアウトが取る幅。
  private func renderedWidth<V: View>(_ view: V, width: CGFloat) -> CGFloat {
    NSHostingController(rootView: view).sizeThatFits(in: NSSize(width: width, height: 40)).width
  }

  private func pullRequestRow() throws -> DispatchItem {
    let sections = DispatchSectionBuilder.build(.designSample)
    return try XCTUnwrap(sections.first { $0.title == "Pull requests" }?.items.first)
  }

  /// 固定幅の部品（番号・レビュー状態・checkout → worktree・開く）の合計にも満たない幅でも、行は
  /// 割り当て幅を越えない（狭い窓でカードからはみ出さない）。
  func testRowNeverExceedsTheAllottedWidth() throws {
    let item = try pullRequestRow()
    XCTAssertNotNil(item.reviewNote, "前提: レビュー状態の付いた PR 行")
    let row = DispatchRow(
      item: item, selected: false, onTap: {}, onHoverEnter: {}, onOpenWeb: {})
    let allotted: CGFloat = 200

    XCTAssertLessThanOrEqual(renderedWidth(row, width: allotted), allotted)
  }

  /// 縮みうる文字は、「先頭 1 文字＋…」で読める幅があれば出し、無ければまったく出さない。
  func testTruncatingTextDrawsNothingRatherThanAFragment() {
    let slot = DispatchTruncatingSlot("feat: session restore") { Text($0) }
    let natural = renderedWidth(slot, width: 1000)
    XCTAssertGreaterThan(natural, 0)

    XCTAssertEqual(renderedWidth(slot, width: 4), 0, "「…」も付かない幅なら欠片を描かない")
    let shortened = renderedWidth(slot, width: natural / 2)
    XCTAssertGreaterThan(shortened, 0, "読める幅があれば末尾省略で出す")
    XCTAssertLessThanOrEqual(shortened, natural / 2)
    XCTAssertEqual(renderedWidth(slot, width: 1000), natural, "入る幅なら全文のまま")
  }
}
