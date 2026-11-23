import AppKit
import OrbeTestSupport
import XCTest

@testable import Orbe

/// PR の画面の上のバーにある、今のファイルのボタンと変更ファイルの一覧。左の列を閉じている間、本体の PR の diff のファイルの
/// ボタンが出て、押すと「変更ファイル N」の一覧が出る。一覧の並びは左の列の今の表示と同じ（ツリー表示ならツリーを全部開いた
/// ときの順、リスト表示ならパスの順）で、表示を替えれば開いている一覧も並び替わる。確認済みのファイルは名前を弱い色にし、
/// 開いている間に付け外しすれば、その行も替わる。行を決めると、その PR の diff が本体に出て、左の列の一覧でもその行が選ばれる。
///
/// 壊れると何が起きるか。左の列を閉じた PR の画面で、別のファイルの差分へ移れない。左の列を開いているときと閉じているときで
/// 「次のファイル」が違う。一覧で確認済みかどうかが読めない・古いまま。一覧から選んだファイルと、左の列で選ばれている
/// ファイルが食い違う。
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
    XCTAssertTrue(hosted.pane.pullRequest.asTree, "前提: ツリー表示")
    XCTAssertEqual(
      [1, 2].compactMap { file($0)?.directory }, ["src", ""], "ツリーの順（フォルダが先）")
    XCTAssertEqual(file(2)?.isDimmed, true, "確認済みは弱い色")
    XCTAssertEqual(file(1)?.isDimmed, false)
    XCTAssertEqual(itemList.selection, hosted.pane.diff.map { AnyHashable($0.id) })

    // 左の列を閉じた知らせは main のキューで遅れて届き、届いたときにも一覧の中身を作り直す。その知らせを先に処理し終えてから、
    // 確認済みの変化だけで行が替わることを見る。
    nextTurn()
    state.setViewed(false, paths: ["b.swift"])
    pumpMain(until: { file(2)?.isDimmed == false }, "開いたままの一覧も替わる")

    hosted.pane.sidebar.setPullRequestFilesAsTree(false)
    pumpMain(
      until: { [1, 2].compactMap { file($0)?.name } == ["b.swift", "a.swift"] },
      "リスト表示にすると、開いたままの一覧もパスの順に並び替わる")
    XCTAssertEqual(
      itemList.selection, hosted.pane.diff.map { AnyHashable($0.id) }, "選択は同じファイルに残る")

    itemList.list.list.mouseDown(
      with: itemList.list.list.mouseEvent(
        .leftMouseDown, at: NSPoint(x: 40, y: 1.5 * Theme.Layout.editorItemListRow)))
    XCTAssertEqual(hosted.pane.diff?.id.path, "b.swift")
    XCTAssertFalse(itemList.isOpen)
    XCTAssertTrue(hosted.window.firstResponder === hosted.pane.focusTarget, "本文へ")
    XCTAssertEqual(hosted.pane.pullRequest.selection, .file("b.swift"), "左の列の一覧でも選ばれる")
  }

  /// 左の列で閉じたフォルダの中のファイルを一覧から選ぶと、左の列はそのフォルダを開いて、そのファイルの行を選ぶ（本体の diff と
  /// 左の列の選択が食い違わない）。
  func testChoosingAFileInAClosedFolderOpensTheFolderAndSelectsTheRow() throws {
    let hosted = host(try registeredRoot())
    shownWithRows(hosted)
    pumpMain(until: { hosted.pane.diff?.id.path == "src/a.swift" }, "前提: 本体に src/a.swift の diff")
    let panel = hosted.pane.pullRequest
    XCTAssertTrue(panel.asTree, "前提: ツリー表示")
    hosted.pane.toggleSidebar()
    pumpMain(until: { hosted.pane.shell.currentItem != nil }, "左の列を閉じるとボタンが出る")
    choose("b.swift", hosted)
    XCTAssertEqual(panel.selection, .file("b.swift"))
    panel.toggleFolder("src")
    XCTAssertNil(panel.layout.index[.file("src/a.swift")], "前提: フォルダ src を閉じる")

    choose("a.swift", hosted)
    XCTAssertEqual(hosted.pane.diff?.id.path, "src/a.swift")
    XCTAssertFalse(panel.closedFolders.contains("src"), "閉じたフォルダを開く")
    XCTAssertEqual(panel.selection, .file("src/a.swift"), "左の列でもそのファイルの行を選ぶ")
  }

  /// 上のバーの一覧を開き、名前 `name` のファイルの行を押す（製品の押下と同じ入口）。
  private func choose(_ name: String, _ hosted: Hosted) {
    hosted.pane.shell.toggleItemList()
    let itemList = hosted.pane.itemList
    guard let rows = itemList.content?.rows,
      let index = (0..<rows.count).first(where: {
        if case .file(let file) = rows.row(at: $0) { file.name == name } else { false }
      })
    else { return XCTFail("一覧に \(name) の行") }
    itemList.list.list.mouseDown(
      with: itemList.list.list.mouseEvent(
        .leftMouseDown,
        at: NSPoint(x: 40, y: (CGFloat(index) + 0.5) * Theme.Layout.editorItemListRow)))
    XCTAssertEqual(hosted.pane.diff?.id.path.hasSuffix(name), true, "\(name) の diff が本体に出る")
  }
}
