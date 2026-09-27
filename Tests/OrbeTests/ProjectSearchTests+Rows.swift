import AppKit
import OrbeEditorCore
import XCTest

@testable import Orbe

/// 結果の列の操作——↑↓ は選択だけを動かして開かない、← → で畳む・開く・親へ・最初の一致へ、Enter は一致なら開いて本文へ
/// （見出しならそのファイルの最後の一致）、⌘↓ / ⌘↑ で入力欄と行き来、F4 / ⇧F4 は次・前の一致を開いて端で回り畳んだ
/// まとまりは開く。
///
/// 壊れると何が起きるか。↑↓ で渡るたびにタブが増える。← → で選択が消える、畳んだまとまりの中へ F4 が入れない。最後の
/// 一致の次で F4 が止まる。Enter が見出しを開閉するだけで開けない。
extension ProjectSearchTests {
  typealias RowID = ProjectSearch.RowID

  /// `a.txt` に 2 件、`b.txt` に 1 件の結果。開いた行と、本文へ焦点を移したかを記録する。
  func rowsFixture() throws -> (search: ProjectSearch, opened: () -> [(RowID, Bool)]) {
    let f = try fixture()
    try f.repo.write("a.txt", "needle\nneedle\n")
    try f.repo.write("b.txt", "needle\n")
    search(f.search, "needle")
    var opened: [(RowID, Bool)] = []
    f.search.onOpen = { id, focusText in opened.append((id, focusText)) }
    return (f.search, { opened })
  }

  func match(_ path: String, _ index: Int) -> RowID { RowID(path: path, match: index) }
  func header(_ path: String) -> RowID { RowID(path: path, match: nil) }

  func testArrowsMoveTheSelectionWithoutOpening() throws {
    let (search, opened) = try rowsFixture()
    XCTAssertEqual(
      search.rows.map(\.id),
      [
        header("a.txt"), match("a.txt", 0), match("a.txt", 1), header("b.txt"), match("b.txt", 0),
      ])

    search.moveSelection(by: 1)
    XCTAssertEqual(search.selection, header("a.txt"), "未選択なら先頭")
    search.moveSelection(by: 1)
    search.moveSelection(by: 1)
    XCTAssertEqual(search.selection, match("a.txt", 1))
    search.moveSelection(by: 10)
    XCTAssertEqual(search.selection, match("b.txt", 0), "端で止まる")
    search.moveSelection(by: -1)
    XCTAssertEqual(search.selection, header("b.txt"))
    XCTAssertTrue(opened().isEmpty, "↑↓ では開かない")
  }

  func testLeftAndRightCollapseExpandAndMoveBetweenAHeaderAndItsMatches() throws {
    let (search, _) = try rowsFixture()
    search.select(match("a.txt", 1))

    search.moveLeft()
    XCTAssertEqual(search.selection, header("a.txt"), "一致の ← は親の見出しへ")
    search.moveLeft()
    XCTAssertEqual(
      search.rows.map(\.id), [header("a.txt"), header("b.txt"), match("b.txt", 0)], "畳む")
    XCTAssertEqual(search.selection, header("a.txt"))
    search.moveRight()
    XCTAssertEqual(search.rows.count, 5, "開く")
    search.moveRight()
    XCTAssertEqual(search.selection, match("a.txt", 0), "開いた見出しの → は最初の一致へ")
  }

  func testEnterOpensTheSelectedMatchOrTheLastMatchOfAHeader() throws {
    let (search, opened) = try rowsFixture()
    search.select(match("b.txt", 0))
    search.activateSelection()
    search.select(header("a.txt"))
    search.activateSelection()

    XCTAssertEqual(opened().map(\.0), [match("b.txt", 0), match("a.txt", 1)])
    XCTAssertEqual(opened().map(\.1), [true, true], "Enter は本文へ焦点を移す")
    XCTAssertEqual(search.selection, match("a.txt", 1))
  }

  /// F4 / ⇧F4 は選択の次・前の一致を開き、端では先頭・末尾へ回り、畳んだまとまりの中へは開いて入る。
  func testStepWrapsAroundAndOpensCollapsedFiles() throws {
    let (search, opened) = try rowsFixture()

    search.step(forward: false)
    XCTAssertEqual(search.selection, match("b.txt", 0), "未選択の ⇧F4 は末尾")
    search.step(forward: true)
    XCTAssertEqual(search.selection, match("a.txt", 0), "末尾の次は先頭へ回る")
    search.step(forward: false)
    XCTAssertEqual(search.selection, match("b.txt", 0), "先頭の前は末尾へ回る")

    search.toggleCollapse("a.txt")
    search.step(forward: true)
    XCTAssertEqual(search.selection, match("a.txt", 0))
    XCTAssertFalse(search.collapsed.contains("a.txt"), "畳んだまとまりは開いて入る")

    search.select(header("b.txt"))
    search.step(forward: false)
    XCTAssertEqual(search.selection, match("a.txt", 1), "見出しの ⇧F4 は前のまとまりの最後の一致")

    XCTAssertEqual(opened().count, 5)
    XCTAssertTrue(opened().allSatisfy(\.1), "F4 は本文へ焦点を移す")
  }

  func testCommandDownEntersTheResultsAndCommandUpLeavesFromTheTop() throws {
    let (search, _) = try rowsFixture()
    search.focusResults()
    XCTAssertEqual(search.selection, header("a.txt"), "未選択なら先頭を選ぶ")
    XCTAssertEqual(search.focusRequest, .results)
    search.focusRequestDidApply()

    search.select(match("a.txt", 0))
    XCTAssertFalse(search.returnToFieldIfAtTop(), "先頭でなければ戻らない")
    search.select(header("a.txt"))
    XCTAssertTrue(search.returnToFieldIfAtTop())
    XCTAssertEqual(search.focusRequest, .field)
  }

  func testCollapseAllFoldsWhileAnyFileIsOpen() throws {
    let (search, _) = try rowsFixture()
    search.toggleCollapse("a.txt")
    search.toggleCollapseAll()
    XCTAssertEqual(search.rows.map(\.id), [header("a.txt"), header("b.txt")], "1 つでも開いていれば畳む")
    search.toggleCollapseAll()
    XCTAssertEqual(search.rows.count, 5, "全部畳んでいれば開く")
  }
}
