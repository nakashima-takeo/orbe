import AppKit
import OrbeTestSupport
import XCTest

@testable import Orbe

/// PR の画面の上のバーにある、今のファイルのボタンと変更ファイルの一覧。左の列を閉じている間、本体の PR の diff のファイルの
/// ボタンが出て、押すと「変更ファイル N」の一覧（リスト表示と同じ順）が出る。確認済みのファイルは名前を弱い色にし、開いて
/// いる間に付け外しすれば、その行も替わる。行を決めると、その PR の diff が本体に出て、左の列の一覧でもその行が選ばれる。
///
/// 壊れると何が起きるか。左の列を閉じた PR の画面で、別のファイルの差分へ移れない。一覧で確認済みかどうかが読めない・古い
/// まま。一覧から選んだファイルと、左の列で選ばれているファイルが食い違う。
extension PullRequestPaneTests {
  func testTheChangedFilesListOpensThePullRequestDiffAndShowsTheViewedFiles() throws {
    let hosted = host(try registeredRoot())
    shownWithRows(hosted)
    pumpMain(
      until: { hosted.pane.diff?.id.path == "src/a.swift" }, "前提: 本体に列の先頭のファイルの diff が自動で開く")
    let state = try XCTUnwrap(hosted.pane.pullRequest.state)
    state.setViewed(true, paths: ["b.swift"])
    hosted.pane.toggleSidebar()
    pumpMain(until: { hosted.pane.shell.currentItem != nil }, "左の列を閉じるとボタンが出る")

    hosted.pane.shell.toggleItemList()
    let itemList = hosted.pane.itemList
    let rows = try XCTUnwrap(itemList.content?.rows)
    XCTAssertEqual(
      rows.row(at: 0),
      .heading(
        title: L10n.string(.editorPrFiles, hosted.pane.localization.language), count: 2, key: nil))
    func file(_ index: Int) -> EditorItemListRow.File? {
      guard case .file(let file) = itemList.content?.rows.row(at: index) else { return nil }
      return file
    }
    XCTAssertEqual([1, 2].compactMap { file($0)?.name }, ["b.swift", "a.swift"], "リスト表示と同じ順")
    XCTAssertEqual(file(1)?.isDimmed, true, "確認済みは弱い色")
    XCTAssertEqual(file(2)?.isDimmed, false)
    XCTAssertEqual(itemList.selection, hosted.pane.diff.map { AnyHashable($0.id) })

    // 左の列を閉じた知らせは main のキューで遅れて届き、届いたときにも一覧の中身を作り直す。その知らせを先に処理し終えてから、
    // 確認済みの変化だけで行が替わることを見る。
    nextTurn()
    state.setViewed(false, paths: ["b.swift"])
    pumpMain(until: { file(1)?.isDimmed == false }, "開いたままの一覧も替わる")

    itemList.list.list.mouseDown(
      with: itemList.list.list.mouseEvent(
        .leftMouseDown, at: NSPoint(x: 40, y: 1.5 * Theme.Layout.editorItemListRow)))
    XCTAssertEqual(hosted.pane.diff?.id.path, "b.swift")
    XCTAssertFalse(itemList.isOpen)
    XCTAssertTrue(hosted.window.firstResponder === hosted.pane.focusTarget, "本文へ")
    XCTAssertEqual(hosted.pane.pullRequest.selection, .file("b.swift"), "左の列の一覧でも選ばれる")
  }
}
