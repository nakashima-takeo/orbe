import SwiftUI
import XCTest

@testable import Orbe

/// worktree パレットの行（`WorktreePaletteRow`）の幅の契約。
///
/// リストは行を個別に測るので、行が割り当て幅を越えると、その行だけがカードからはみ出して右端の印の
/// 位置がそろわなくなる。縮みきった文字が 1 文字だけの欠片で残ると、「…」の無い読めない字が出る。
@MainActor
final class WorktreePaletteRowTests: OrbeTestCase {

  /// 提案幅 `width` を与えたときにレイアウトが取る幅。
  private func renderedWidth<V: View>(_ view: V, width: CGFloat) -> CGFloat {
    NSHostingController(rootView: view).sizeThatFits(in: NSSize(width: width, height: 40)).width
  }

  private func remoteBranchRow() throws -> WorktreePaletteItem {
    let sections = WorktreePaletteSectionBuilder.build(.designSample)
    return try XCTUnwrap(sections.first { $0.title == "Remote branches" }?.items.first)
  }

  /// 名前と補足の合計にも満たない幅でも、行は割り当て幅を越えない（狭い窓でカードからはみ出さない）。
  func testRowNeverExceedsTheAllottedWidth() throws {
    let row = WorktreePaletteRow(
      item: try remoteBranchRow(), selected: false, onTap: {}, onHoverEnter: {})
    let allotted: CGFloat = 120

    XCTAssertLessThanOrEqual(renderedWidth(row, width: allotted), allotted)
  }

  /// 縮みうる文字は、「先頭 1 文字＋…」で読める幅があれば出し、無ければまったく出さない。
  func testTruncatingTextDrawsNothingRatherThanAFragment() {
    let slot = WorktreePaletteTruncatingSlot("feat: session restore") { Text($0) }
    let natural = renderedWidth(slot, width: 1000)
    XCTAssertGreaterThan(natural, 0)

    XCTAssertEqual(renderedWidth(slot, width: 4), 0, "「…」も付かない幅なら欠片を描かない")
    let shortened = renderedWidth(slot, width: natural / 2)
    XCTAssertGreaterThan(shortened, 0, "読める幅があれば末尾省略で出す")
    XCTAssertLessThanOrEqual(shortened, natural / 2)
    let fullText = renderedWidth(Text("feat: session restore").fixedSize(), width: 1000)
    XCTAssertEqual(natural, fullText, "入る幅なら全文のまま")

    let padded = WorktreePaletteTruncatingSlot("feat: session restore", leading: 8) { Text($0) }
    XCTAssertEqual(renderedWidth(padded, width: 1000), natural + 8, "出すときは余白を足す")
    XCTAssertEqual(renderedWidth(padded, width: 10), 0, "畳むときは余白ごと幅 0")
  }
}
