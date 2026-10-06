import AppKit
import OrbeEditorCore
import XCTest

@testable import Orbe

/// 結果の列の操作——↑↓ で一致へ動けば仮のタブで開き（見出しでは開かない）、押している間は開かず離した後に開く、← → で畳む・開く・
/// 親へ・最初の一致へ、Enter は一致なら普通のタブで開いて本文へ（見出しならそのファイルの最後の一致）、⌘↓ / ⌘↑ で入力欄と
/// 行き来、F4 / ⇧F4 は次・前の一致を仮のタブで開いて端で回り畳んだまとまりは開く。
///
/// 壊れると何が起きるか。↑↓ でたどっても中身が見えない、押し続けると 1 件ごとにファイルを読んで選択の移動が遅れる。
/// Enter の後に前の選択が遅れて開いて、Enter で開いたファイルを入れ替える。← → で選択が消える、畳んだまとまりの中へ
/// F4 が入れない。最後の一致の次で F4 が止まる。Enter が見出しを開閉するだけで開けない。
extension ProjectSearchTests {
  typealias RowID = ProjectSearch.RowID

  struct RowsFixture {
    let search: ProjectSearch
    /// 開いた行と開き方。
    let opened: () -> [(RowID, ProjectSearch.Opening)]
    /// キーの開きの窓を閉じる（最後の押下から窓の長さが過ぎた）。
    let closeWindow: () -> Void
  }

  /// `a.txt` に 2 件、`b.txt` に 1 件の結果。開いた行と開き方を記録する。キーの開きの窓は手で閉じる。
  func rowsFixture() throws -> RowsFixture {
    let f = try fixture()
    try f.repo.write("a.txt", "needle\nneedle\n")
    try f.repo.write("b.txt", "needle\n")
    search(f.search, "needle")
    var opened: [(RowID, ProjectSearch.Opening)] = []
    f.search.onOpen = { id, opening in opened.append((id, opening)) }
    var window: (() -> Void)?
    f.search.navigationDelay.schedule = { _, fire in window = fire }
    return RowsFixture(search: f.search, opened: { opened }, closeWindow: { window?() })
  }

  func match(_ path: String, _ index: Int) -> RowID { RowID(path: path, match: index) }
  func header(_ path: String) -> RowID { RowID(path: path, match: nil) }

  /// 平らな行の同一性を番号の順に。
  func rowIDs(_ search: ProjectSearch) -> [RowID] {
    (0..<search.rowCount).map { search.row(at: $0).id }
  }

  /// ↑↓ は選択を動かし、一致へ動けば仮のタブで開いて焦点に触らない。見出しへ動いた・端で動かなかったときは開かない。
  /// 窓の外の押下はそのつどすぐ開く。
  func testArrowsOpenTheMatchTheyMoveToAsAPreview() throws {
    let f = try rowsFixture()
    let search = f.search
    let opened = f.opened
    let closeWindow = f.closeWindow
    XCTAssertEqual(
      rowIDs(search),
      [
        header("a.txt"), match("a.txt", 0), match("a.txt", 1), header("b.txt"), match("b.txt", 0),
      ])

    search.moveSelection(by: 1, isRepeat: false)
    XCTAssertEqual(search.selection, header("a.txt"), "未選択なら先頭")
    XCTAssertTrue(opened().isEmpty, "見出しでは開かない")
    closeWindow()
    search.moveSelection(by: 1, isRepeat: false)
    XCTAssertEqual(opened().map(\.0), [match("a.txt", 0)], "窓の外の押下はすぐ開く")
    XCTAssertEqual(opened().last?.1, .browse, "仮のタブで開いて焦点に触らない")
    closeWindow()
    search.moveSelection(by: 10, isRepeat: false)
    XCTAssertEqual(search.selection, match("b.txt", 0), "端で止まる")
    closeWindow()
    search.moveSelection(by: 1, isRepeat: false)
    closeWindow()
    XCTAssertEqual(opened().count, 2, "動かなければ開かない")
    search.moveSelection(by: -1, isRepeat: false)
    XCTAssertEqual(search.selection, header("b.txt"))
    closeWindow()
    XCTAssertEqual(opened().count, 2, "見出しへ動いても開かない")
  }

  /// 押し続けると、押し始めの 1 件はすぐ開き、押している間（キーリピート）は窓が閉じても開かず、離してから窓が閉じたら最後の
  /// 選択だけを開く。窓の中の押下も待ち、離してから窓が閉じたら最後の選択だけを開く。
  func testHoldingAnArrowOpensOnlyTheFirstAndTheLastMatch() throws {
    let f = try rowsFixture()
    f.search.select(match("a.txt", 0))

    f.search.moveSelection(by: 1, isRepeat: false)
    XCTAssertEqual(f.opened().map(\.0), [match("a.txt", 1)], "押し始めはすぐ開く")
    f.closeWindow()  // リピートが始まるまでの初期遅延で窓が閉じる
    f.search.moveSelection(by: 1, isRepeat: true)
    f.search.moveSelection(by: 1, isRepeat: true)
    f.closeWindow()
    XCTAssertEqual(f.opened().count, 1, "押している間は窓が閉じても開かない")
    f.search.navigationKeyDidRelease()
    XCTAssertEqual(f.opened().count, 1, "離してすぐには開かない")
    f.closeWindow()
    XCTAssertEqual(
      f.opened().map(\.0), [match("a.txt", 1), match("b.txt", 0)], "離して窓が閉じたら最後の選択を開く")
    XCTAssertEqual(f.opened().last?.1, .browse)

    f.search.select(match("a.txt", 0))
    f.search.moveSelection(by: 1, isRepeat: false)
    f.search.navigationKeyDidRelease()
    f.search.moveSelection(by: 2, isRepeat: false)
    f.search.navigationKeyDidRelease()
    XCTAssertEqual(f.opened().count, 3, "窓の中の押下は待つ")
    f.closeWindow()
    XCTAssertEqual(f.opened().last?.0, match("b.txt", 0), "窓が閉じたら最後の選択だけ")
    XCTAssertEqual(f.opened().count, 4)
  }

  /// 離したことが届かないまま（押したまま焦点が移る等）でも、次のリピートでない押下とすぐ開く操作で押し続けは解ける。結果の
  /// 列から焦点が外れたら、待っている開きは捨てる（人の注意が結果から移った）。
  func testAMissedReleaseIsResolved() throws {
    let holding = { (f: RowsFixture) in
      f.search.select(self.match("a.txt", 0))
      f.search.moveSelection(by: 1, isRepeat: false)
      f.closeWindow()
      f.search.moveSelection(by: -1, isRepeat: true)
      f.closeWindow()
      XCTAssertEqual(f.opened().count, 1, "前提: 押し続けで待っている")
    }

    let pressed = try rowsFixture()
    holding(pressed)
    pressed.search.moveSelection(by: 3, isRepeat: false)
    XCTAssertEqual(pressed.opened().last?.0, match("b.txt", 0), "次のリピートでない押下はすぐ開く")

    let blurred = try rowsFixture()
    holding(blurred)
    blurred.search.focusDidChange(.results, focused: false)
    blurred.search.navigationKeyDidRelease()
    blurred.closeWindow()
    XCTAssertEqual(blurred.opened().count, 1, "焦点が外れたら待っている開きを捨てる")

    let committed = try rowsFixture()
    holding(committed)
    committed.search.activateSelection()
    committed.search.moveSelection(by: 1, isRepeat: false)
    XCTAssertEqual(committed.opened().count, 3, "すぐ開く操作の後の押下はすぐ開く")
  }

  /// 窓が閉じたとき、その時点の選択が一致でなければ開かない（見出しへ動いた・選択を外した・結果が差し替わった）。
  func testAPendingOpenSkipsWhatIsNoLongerAMatch() throws {
    let f = try rowsFixture()
    f.search.select(match("a.txt", 0))
    f.search.moveSelection(by: 1, isRepeat: false)
    f.search.moveSelection(by: 1, isRepeat: false)
    f.search.moveLeft()
    f.search.navigationKeyDidRelease()
    f.closeWindow()
    XCTAssertEqual(f.opened().count, 1, "見出しへ動いていれば開かない")

    f.search.select(match("a.txt", 0))
    f.search.moveSelection(by: 1, isRepeat: true)
    f.search.escapeInResults()
    f.search.navigationKeyDidRelease()
    f.closeWindow()
    XCTAssertEqual(f.opened().count, 1, "選択を外していれば開かない")
  }

  /// すぐ開く操作（クリック・ダブルクリック・Enter・F4）は待っているキーの開きを捨てる——後から前の選択が開かない。
  func testOpeningAtOnceDropsAPendingArrowOpen() throws {
    let cases: [(String, (ProjectSearch) -> Void)] = [
      ("クリック", { $0.click(RowID(path: "b.txt", match: 0)) }),
      ("ダブルクリック", { $0.doubleClick(RowID(path: "b.txt", match: 0)) }),
      ("Enter", { $0.activateSelection() }),
      ("F4", { $0.step(forward: true) }),
    ]
    for (name, openAtOnce) in cases {
      let f = try rowsFixture()
      f.search.select(match("a.txt", 0))
      f.search.moveSelection(by: 1, isRepeat: false)
      f.search.moveSelection(by: -1, isRepeat: true)
      openAtOnce(f.search)
      let count = f.opened().count
      f.search.navigationKeyDidRelease()
      f.closeWindow()
      XCTAssertEqual(f.opened().count, count, "\(name): 待っていた開きは走らない")
    }
  }

  /// → で開いた見出しから最初の一致へ動けば仮のタブで開く。畳んだ見出しを開くだけなら開かない。
  func testRightToTheFirstMatchOpensIt() throws {
    let f = try rowsFixture()
    let search = f.search
    let opened = f.opened
    let closeWindow = f.closeWindow
    search.select(header("a.txt"))
    search.toggleCollapse("a.txt")
    search.moveRight(isRepeat: false)
    XCTAssertTrue(opened().isEmpty, "見出しを開くだけなら開かない")
    closeWindow()
    search.moveRight(isRepeat: false)
    XCTAssertEqual(opened().map(\.0), [match("a.txt", 0)])
    XCTAssertEqual(opened().last?.1, .browse)
  }

  func testLeftAndRightCollapseExpandAndMoveBetweenAHeaderAndItsMatches() throws {
    let f = try rowsFixture()
    let search = f.search
    search.select(match("a.txt", 1))

    search.moveLeft()
    XCTAssertEqual(search.selection, header("a.txt"), "一致の ← は親の見出しへ")
    search.moveLeft()
    XCTAssertEqual(
      rowIDs(search), [header("a.txt"), header("b.txt"), match("b.txt", 0)], "畳む")
    XCTAssertEqual(search.selection, header("a.txt"))
    search.moveRight(isRepeat: false)
    XCTAssertEqual(search.rowCount, 5, "開く")
    search.moveRight(isRepeat: false)
    XCTAssertEqual(search.selection, match("a.txt", 0), "開いた見出しの → は最初の一致へ")
  }

  func testEnterOpensTheSelectedMatchOrTheLastMatchOfAHeader() throws {
    let f = try rowsFixture()
    let search = f.search
    let opened = f.opened
    search.select(match("b.txt", 0))
    search.activateSelection()
    search.select(header("a.txt"))
    search.activateSelection()

    XCTAssertEqual(opened().map(\.0), [match("b.txt", 0), match("a.txt", 1)])
    XCTAssertEqual(opened().map(\.1), [.commit, .commit], "Enter は普通のタブで開いて本文へ")
    XCTAssertEqual(search.selection, match("a.txt", 1))
  }

  /// F4 / ⇧F4 は選択の次・前の一致を開き、端では先頭・末尾へ回り、畳んだまとまりの中へは開いて入る。
  func testStepWrapsAroundAndOpensCollapsedFiles() throws {
    let f = try rowsFixture()
    let search = f.search
    let opened = f.opened

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
    XCTAssertTrue(opened().allSatisfy { $0.1 == .step }, "F4 は仮のタブで開いて本文へ")
  }

  func testCommandDownEntersTheResultsAndCommandUpLeavesFromTheTop() throws {
    let f = try rowsFixture()
    let search = f.search
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
    let f = try rowsFixture()
    let search = f.search
    search.toggleCollapse("a.txt")
    search.toggleCollapseAll()
    XCTAssertEqual(rowIDs(search), [header("a.txt"), header("b.txt")], "1 つでも開いていれば畳む")
    search.toggleCollapseAll()
    XCTAssertEqual(search.rowCount, 5, "全部畳んでいれば開く")
  }
}
