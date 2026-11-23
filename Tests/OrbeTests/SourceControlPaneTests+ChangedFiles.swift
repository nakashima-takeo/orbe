import AppKit
import OrbeTestSupport
import XCTest

@testable import Orbe

/// Changes の画面の上のバーにある、今のファイルのボタンと変更ファイルの一覧——左の列を閉じている間だけ、本体の diff のファイル
/// （状態の字と名前）のボタンが出て、押すか ⌘P で、2 区分（「ステージされている変更」「変更」）の一覧が出る。開いたときの
/// 選択は本体の diff の行で、↑↓ は見出しを飛ばす。行を決めると、その diff が本体に出て、一覧が閉じ、本文へフォーカスが移る。
///
/// 壊れると何が起きるか。左の列を閉じると、別のファイルの差分へ移る手段が無くなる。ボタンが本体と違うファイルを示す。
/// 左の列を開いても一覧が残る。一覧から選んでも本文にフォーカスが来ない・左の列の選択が古いまま。status が変わっても開いた
/// 一覧が古い行のまま。
extension SourceControlPaneTests {
  /// ステージ済みの追加 1 つ（src/new.swift）と、変更 2 つ（a.txt・b.txt）の場。左の列は開いていて、本体に先頭の行の
  /// diff が出ている。
  private func changedFilesHost() throws -> Hosted {
    let repo = try TempGitRepo()
    try repo.write("src/new.swift", "new\n")
    XCTAssertTrue(repo.git(["add", "-A"]).isSuccess)
    try repo.write("a.txt", "edited\n")
    try repo.write("b.txt", "untracked\n")
    let hosted = host(repo)
    pumpMain(
      until: { hosted.scm.changes.staged.count == 1 && hosted.scm.changes.changes.count == 2 },
      "前提: 2 区分が揃う")
    pumpMain(until: { hosted.pane.diff != nil }, "前提: 本体に diff が出る")
    return hosted
  }

  private func closeSidebar(_ hosted: Hosted) {
    hosted.pane.toggleSidebar()
    pumpMain(until: { hosted.pane.shell.currentItem != nil }, "左の列を閉じるとボタンが出る")
  }

  private func listKey(_ hosted: Hosted, _ chars: String) {
    hosted.pane.itemList.list.list.keyDown(with: .key(chars, []))
  }

  /// 行の列の行 `index` を押す（製品の押下と同じ入口）。
  private func click(_ hosted: Hosted, row index: Int) {
    let list = hosted.pane.itemList.list.list
    let point = NSPoint(x: 40, y: (CGFloat(index) + 0.5) * Theme.Layout.editorItemListRow)
    list.mouseDown(with: list.mouseEvent(.leftMouseDown, at: point))
  }

  private func fileRow(_ hosted: Hosted, _ index: Int) -> EditorItemListRow.File? {
    guard case .file(let file) = hosted.pane.itemList.content?.rows.row(at: index) else {
      return nil
    }
    return file
  }

  /// ボタンは、左の列を閉じている間だけ出て、本体の diff のファイルの状態の字と名前を示す。左の列を開くと消える。
  func testTheButtonShowsTheBodysDiffOnlyWhileTheSidebarIsClosed() throws {
    let hosted = try changedFilesHost()
    XCTAssertNil(hosted.pane.shell.currentItem, "左の列を開いている間は出ない")

    closeSidebar(hosted)
    guard case .diff(let subject)? = hosted.pane.shell.currentItem else {
      return XCTFail("diff のボタン")
    }
    XCTAssertEqual(subject.key, hosted.pane.diff?.id)
    let header = subject.header(scm: hosted.scm)
    XCTAssertEqual(header.name, "new.swift")
    XCTAssertEqual(header.badge, .added)

    hosted.pane.toggleSidebar()
    pumpMain(until: { hosted.pane.shell.currentItem == nil }, "左の列を開くと消える")
  }

  /// 押すと 2 区分の一覧が出て、開いたときの選択は本体の diff の行。↓ は見出しを飛ばす。行を押すと、その diff が本体に出て、
  /// 一覧が閉じ、本文へフォーカスが移り、左の列の一覧でもその行が選ばれる。
  func testTheListShowsBothSectionsAndOpensTheChosenDiff() throws {
    let hosted = try changedFilesHost()
    closeSidebar(hosted)
    hosted.pane.shell.toggleItemList()
    let itemList = hosted.pane.itemList
    XCTAssertTrue(itemList.isOpen)
    XCTAssertTrue(hosted.pane.focusIsInItemList)
    let rows = try XCTUnwrap(itemList.content?.rows)
    XCTAssertEqual(rows.count, 5)
    let language = hosted.pane.localization.language
    XCTAssertEqual(
      rows.row(at: 0), .heading(title: L10n.string(.editorScmStaged, language), count: 1, key: nil))
    XCTAssertEqual(
      rows.row(at: 2),
      .heading(title: L10n.string(.editorScmChanges, language), count: 2, key: nil))
    XCTAssertEqual(fileRow(hosted, 1)?.directory, "src")
    XCTAssertEqual(fileRow(hosted, 1)?.badge, .added)
    XCTAssertEqual([3, 4].compactMap { fileRow(hosted, $0)?.name }, ["a.txt", "b.txt"])
    XCTAssertEqual(
      itemList.selection, hosted.pane.diff.map { AnyHashable($0.id) }, "本体の diff の行を選ぶ")

    listKey(hosted, String(UnicodeScalar(NSEvent.SpecialKey.downArrow.rawValue)!))
    XCTAssertEqual(
      itemList.selection,
      AnyHashable(EditorDiff.Key(root: hosted.repo.root, path: "a.txt", kind: .workingTree)),
      "見出しを飛ばす")

    click(hosted, row: 4)
    let chosen = EditorDiff.Key(root: hosted.repo.root, path: "b.txt", kind: .workingTree)
    XCTAssertEqual(hosted.pane.diff?.id, chosen)
    XCTAssertFalse(itemList.isOpen)
    XCTAssertTrue(hosted.window.firstResponder === hosted.pane.focusTarget, "本文へ")
    XCTAssertEqual(hosted.scm.selection, ScmRowID(section: .changes, path: "b.txt"))
    guard case .diff(let subject)? = hosted.pane.shell.currentItem else {
      return XCTFail("ボタンは残る")
    }
    XCTAssertEqual(subject.key, chosen, "ボタンも選んだファイルを示す")
  }

  /// ⌘P はボタンを押すのと同じ。開いている間に status が変わると、一覧の行も替わる。左の列を開くと、一覧は閉じる。
  func testCommandPOpensTheListAndItFollowsTheStatus() throws {
    let hosted = try changedFilesHost()
    hosted.window.makeFirstResponder(hosted.pane.focusTarget)
    XCTAssertTrue(hosted.pane.performKeyEquivalent(with: .key("p")))
    XCTAssertFalse(hosted.pane.itemList.isOpen, "左の列を開いている間は、⌘P は働かない")

    closeSidebar(hosted)
    XCTAssertTrue(hosted.pane.performKeyEquivalent(with: .key("p")))
    XCTAssertTrue(hosted.pane.itemList.isOpen)

    try hosted.repo.write("c.txt", "more\n")
    pumpMain(until: { hosted.pane.itemList.rowCount == 6 }, "開いたままの一覧に行が増える")
    XCTAssertTrue(hosted.pane.itemList.isOpen)

    hosted.pane.toggleSidebar()
    pumpMain(until: { !hosted.pane.itemList.isOpen }, "左の列を開くと閉じる")
    XCTAssertNil(hosted.pane.shell.currentItem)
  }
}
