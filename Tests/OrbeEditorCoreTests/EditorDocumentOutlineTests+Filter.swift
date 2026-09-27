import Foundation
import XCTest
import os

@testable import OrbeEditorCore

/// 絞り込み——一致とその祖先が残り、取り直した結果は今の文字列の絞り込みと揃うまで見せない。
extension EditorDocumentOutlineTests {
  /// 一致したシンボルとその祖先が残り、一致した字が分かる。空にすれば絞り込まない。
  func testFilteringKeepsMatchesAndTheirAncestors() throws {
    let (document, _) = try open()
    document.wantsOutline = true
    XCTAssertTrue(document.waitUntilCaughtUp())

    document.filterOutline("gr")
    XCTAssertTrue(document.waitUntilCaughtUp())
    let filter = try XCTUnwrap(document.outlineFilter)
    let grow = try index("grow(by:)", in: document)
    XCTAssertEqual(filter.visible, [0, grow], "一致と祖先")
    XCTAssertEqual(filter.matches[grow], [0..<2])
    XCTAssertNil(filter.matches[0], "祖先は一致していない")

    document.filterOutline("")
    XCTAssertNil(document.outlineFilter)
  }

  /// 絞り込み中に取り直した結果は、その絞り込みと揃うまで見せない（結果と絞り込みの番号が食い違わない）。
  func testARefreshedOutlineArrivesTogetherWithItsFilter() throws {
    let (document, surface) = try open(quietDelay: .milliseconds(50))
    document.wantsOutline = true
    document.filterOutline("gr")
    XCTAssertTrue(document.waitUntilCaughtUp())
    var seen: [Bool] = []
    document.onOutlineChange = {
      seen.append(document.outlineFilter?.token == document.outline?.token)
    }

    surface.replace(NSRange(location: 0, length: 0), with: "func grab() {}\n")
    XCTAssertTrue(document.waitUntilCaughtUp())
    XCTAssertFalse(seen.isEmpty)
    XCTAssertTrue(seen.allSatisfy { $0 }, "どの知らせでも結果と絞り込みが揃っている")
    XCTAssertEqual(document.outlineFilter?.visible.count, 3, "grab()・Box・grow(by:)")
  }

  /// 取り直しの結果に添えた絞り込みが今の文字列と違えば、揃うまで見せない。今の文字列の絞り込みが届けば揃えて入れ替え、
  /// 文字列を空にすれば見せていない結果を繰り上げる。今の本文へ写せない結果は捨てる。
  func testAResultFilteredByAnOldPatternWaitsForTheCurrentFilter() throws {
    let (document, _) = try open()
    document.wantsOutline = true
    document.filterOutline("gr")
    XCTAssertTrue(document.waitUntilCaughtUp())
    let shown = try XCTUnwrap(document.outline?.token)

    let refreshed = OutlineExtraction.nest([], version: document.version)
    document.receiveOutline(contents(refreshed, filteredBy: "g"))
    XCTAssertEqual(document.outline?.token, shown, "古い文字列の絞り込みを添えた結果は見せない")
    XCTAssertEqual(document.outlineFilter?.pattern, "gr")
    XCTAssertFalse(document.isCaughtUp)

    var arrived = AnalysisInbox.Contents()
    arrived.outlineFilter = filter(refreshed, "gr")
    document.receiveOutline(arrived)
    XCTAssertEqual(document.outline?.token, refreshed.token, "今の文字列の絞り込みと揃えて入れ替える")
    XCTAssertEqual(document.outlineFilter?.token, refreshed.token)
    XCTAssertTrue(document.isCaughtUp)

    let again = OutlineExtraction.nest([], version: document.version)
    document.receiveOutline(contents(again, filteredBy: "g"))
    document.filterOutline("")
    XCTAssertEqual(document.outline?.token, again.token, "空にすれば見せていない結果を繰り上げる")
    XCTAssertNil(document.outlineFilter)

    let unreachable = OutlineExtraction.nest([], version: document.version + 1)
    document.receiveOutline(contents(unreachable, filteredBy: nil))
    XCTAssertEqual(document.outline?.token, again.token, "写せない版の結果は捨てる")
  }

  /// 絞り込みを空にした後に、前の文字列の絞り込みを添えた結果が届いても、絞り込まずに見せる（空の欄の下で古い文字列の
  /// 絞り込みが残らない）。
  func testAResultArrivingAfterTheFilterIsClearedIsNotFiltered() throws {
    let (document, _) = try open()
    document.wantsOutline = true
    document.filterOutline("gr")
    XCTAssertTrue(document.waitUntilCaughtUp())
    document.filterOutline("")

    let refreshed = OutlineExtraction.nest([], version: document.version)
    document.receiveOutline(contents(refreshed, filteredBy: "gr"))
    XCTAssertEqual(document.outline?.token, refreshed.token)
    XCTAssertNil(document.outlineFilter, "空の文字列の下では絞り込まない")
    XCTAssertTrue(document.isCaughtUp)
  }

  private func contents(_ outline: DocumentOutline, filteredBy pattern: String?)
    -> AnalysisInbox.Contents
  {
    var contents = AnalysisInbox.Contents()
    contents.outline = OutlineOutcome(outline: outline, filter: pattern.map { filter(outline, $0) })
    return contents
  }

  private func filter(_ outline: DocumentOutline, _ pattern: String) -> OutlineFilterResult {
    OutlineFilterResult(
      pattern: pattern, token: outline.token, visible: [], matched: [], matches: [:])
  }

  /// 文字列を変えたり解いたりして外れた絞り込みも、知らせの後に裏へ渡して手放す（シンボルの数に比例する解放を main で
  /// 行わない）。
  func testAReplacedFilterIsHandedToTheBackground() throws {
    let (document, _) = try open()
    document.wantsOutline = true
    XCTAssertTrue(document.waitUntilCaughtUp())
    let notified = OSAllocatedUnfairLock(initialState: 0)
    document.onOutlineChange = { notified.withLock { $0 += 1 } }
    let handed = OSAllocatedUnfairLock(initialState: [(pattern: String, notices: Int)]())
    document.releaseOutlines = { parcel in
      let patterns = parcel.withLock { $0?.filters.map(\.pattern) ?? [] }
      let notices = notified.withLock { $0 }
      handed.withLock { $0 += patterns.map { ($0, notices) } }
    }

    document.filterOutline("g")
    XCTAssertTrue(document.waitUntilCaughtUp())
    document.filterOutline("gr")
    XCTAssertTrue(document.waitUntilCaughtUp())
    document.filterOutline("")
    let released = handed.withLock { $0 }
    XCTAssertEqual(released.map(\.pattern), ["g", "gr"])
    XCTAssertEqual(released.map(\.notices), [2, 3], "それぞれ外れた知らせの後に渡す")
  }
}
