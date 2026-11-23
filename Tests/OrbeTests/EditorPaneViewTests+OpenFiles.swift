import AppKit
import OrbeEditorCore
import OrbeTestSupport
import XCTest

@testable import Orbe

/// 開いているファイルの一覧——上のバーの今のファイルのボタンと、その一覧。ボタンは Files の画面で今の文書があるときだけ出て、
/// 押すと最近使った順の一覧が出る。開いたときの選択は 1 つ前に使ったファイルで、↵ で切り替えると一覧が閉じて本文へ戻る。
/// × で文書を閉じても一覧は開いたまま。→ の詳細から「開いたままにする」「ファイルを閉じる」。印と状態の字が行に出る。
///
/// 壊れると何が起きるか。ボタンを押して ↵ を押しても前のファイルへ戻れない。× で今のファイルを閉じると一覧が閉じる・
/// 別のファイルが閉じる。未保存のファイルが確認なしに閉じる。Changes の画面に Files のボタンが残る。
@MainActor
final class EditorPaneViewOpenFilesTests: OrbeTestCase {
  struct Hosted {
    let tab: TerminalTab
    let window: OrbeWindowFake
    var pane: EditorPaneView { tab.group.view.editor }
    var session: EditorSession { tab.group.editor }
    var itemList: EditorItemList { pane.itemList }
  }

  /// 根の下に `names` のファイルを作って順に開き（最後が今の文書）、本文にフォーカスを置いた面。タブは返す値が持つ。
  func host(_ names: [String] = ["a.txt", "b.txt", "c.txt"]) throws -> Hosted {
    let dir = TestScratch.caseDir
    let tab = TerminalTab.alone(cwd: dir.path, editorSurfaces: EditorSurfaces(queriesRoot: nil))
    let window = try XCTUnwrap(hostEditor(tab, width: 1000, height: 600) as? OrbeWindowFake)
    for name in names {
      let url = dir.appendingPathComponent(name)
      try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      try Data(name.utf8).write(to: url)
      try tab.group.editor.open(url, as: .pinned)
    }
    tab.group.editor.selectScreen(.files)
    if let document = tab.group.editor.activeDocument {
      window.makeFirstResponder(document.surface.responder)
    }
    return Hosted(tab: tab, window: window)
  }

  private func names(_ hosted: Hosted) -> [String] {
    hosted.session.documents.map(\.url.lastPathComponent)
  }

  private func file(_ hosted: Hosted) -> EditorShellModel.CurrentFile? {
    guard case .file(let file) = hosted.pane.shell.currentItem else { return nil }
    return file
  }

  /// 一覧の行 `index` の値。
  private func row(_ hosted: Hosted, _ index: Int) -> EditorItemListRow? {
    hosted.itemList.content.map { $0.rows.row(at: index) }
  }

  private func fileRow(_ hosted: Hosted, _ index: Int) -> EditorItemListRow.File? {
    guard case .file(let file) = row(hosted, index) else { return nil }
    return file
  }

  /// 行の列の行 `index` の右の印の枠を押す（製品の押下と同じ入口）。
  private func pressMark(_ hosted: Hosted, row index: Int) throws {
    let list = hosted.itemList.list.list
    let slot = try XCTUnwrap(
      list.subviews.compactMap { $0 as? EditorItemListRowView }.first {
        $0.row == index && !$0.isHidden
      })
    let mark = try XCTUnwrap(slot.markRect)
    list.mouseDown(with: slot.mouseEvent(.leftMouseDown, at: NSPoint(x: mark.midX, y: mark.midY)))
  }

  /// 行の列の行 `index` を押す。
  private func click(_ hosted: Hosted, row index: Int) {
    let list = hosted.itemList.list.list
    let point = NSPoint(x: 40, y: (CGFloat(index) + 0.5) * Theme.Layout.editorItemListRow)
    list.mouseDown(with: list.mouseEvent(.leftMouseDown, at: point))
  }

  // MARK: - ボタン

  /// ボタンは Files の画面で今の文書があるときだけ出て、今の文書の名前と、根からの相対の親のパスを出す。左の列を閉じても
  /// 出る。Changes の画面・文書が無いときは出ない。
  func testTheButtonShowsTheCurrentFileOnlyOnFiles() throws {
    let hosted = try host(["a.txt", "src/deep/b.swift"])
    XCTAssertEqual(file(hosted)?.name, "b.swift")
    XCTAssertEqual(file(hosted)?.directory, "src/deep/")

    hosted.session.activate(try XCTUnwrap(hosted.session.documents.last))
    XCTAssertEqual(file(hosted)?.directory, "", "根の直下は親のパスなし")

    hosted.pane.toggleSidebar()
    pumpMain(until: { !hosted.pane.sidebar.isOpen })
    XCTAssertNotNil(hosted.pane.shell.currentItem, "左の列を閉じても出る")

    hosted.pane.switchScreen(.changes)
    XCTAssertNil(hosted.pane.shell.currentItem, "Changes の画面では出ない")
    hosted.pane.switchScreen(.files)
    for document in hosted.session.documents { hosted.session.close(document) }
    XCTAssertNil(hosted.pane.shell.currentItem, "文書が無ければ出ない")
  }

  /// 未保存の文書には未保存の印、「ディスクが変わった」の立った文書にはその印が、ボタンと一覧の行に出る。
  func testTheMarksShowOnTheButtonAndTheRows() throws {
    let hosted = try host(["a.txt", "b.txt"])
    let b = try XCTUnwrap(hosted.session.activeDocument)
    b.surface.responder.perform(Selector(("insertText:")), with: "x")
    XCTAssertEqual(file(hosted)?.mark, .unsaved)
    hosted.pane.toggleItemList()
    XCTAssertEqual(fileRow(hosted, 1)?.mark, .unsaved)
    XCTAssertEqual(fileRow(hosted, 2)?.mark, .close, "未保存でなければ ×")

    try Data("theirs".utf8).write(to: b.url)
    pumpMain(until: { b.isDiskChanged }, "外の変更で印が立つ")
    XCTAssertEqual(file(hosted)?.mark, .diskChanged)
    XCTAssertEqual(fileRow(hosted, 1)?.mark, .diskChanged, "開いている一覧も替わる")
  }

  // MARK: - 一覧

  /// 押すと一覧が開き、1 行目は今のファイル（「現在」の札）、以下は最近使った順。開いたときの選択は 2 行目。↵ でその文書が
  /// 本体に出て一覧が閉じ、本文へフォーカスが移る。もう一度開くと、切り替える前の文書が 2 行目にある（2 打で戻れる）。
  func testEnterSwitchesToThePreviouslyUsedFileAndBack() throws {
    let hosted = try host()
    hosted.pane.shell.toggleItemList()
    XCTAssertTrue(hosted.itemList.isOpen)
    XCTAssertTrue(hosted.pane.shell.isItemListOpen, "ボタンは開いている姿")
    XCTAssertTrue(hosted.pane.focusIsInItemList)
    guard case .heading(_, let count, let key) = row(hosted, 0) else {
      return XCTFail("1 行目は見出し")
    }
    XCTAssertEqual(count, 3)
    XCTAssertEqual(key, "⌘P")
    XCTAssertEqual((1...3).compactMap { fileRow(hosted, $0)?.name }, ["c.txt", "b.txt", "a.txt"])
    XCTAssertTrue(fileRow(hosted, 1)?.tags.count == 1, "今のファイルに「現在」の札")
    XCTAssertEqual(hosted.itemList.selection, AnyHashable(hosted.session.documents[1].url))

    hosted.itemList.perform(.enter)
    XCTAssertEqual(names(hosted), ["b.txt", "c.txt", "a.txt"])
    XCTAssertFalse(hosted.itemList.isOpen)
    XCTAssertTrue(hosted.window.firstResponder === hosted.pane.document?.surface.responder)

    hosted.pane.toggleItemList()
    hosted.itemList.perform(.enter)
    XCTAssertEqual(names(hosted), ["c.txt", "b.txt", "a.txt"], "⌘P ↵ で前のファイルへ戻る")
  }

  /// 行のクリックは ↵ と同じ（その文書へ切り替えて閉じる）。ボタンをもう一度押すと閉じて本文へ戻る。
  func testClickingARowSwitchesAndTheButtonToggles() throws {
    let hosted = try host()
    hosted.pane.toggleItemList()
    click(hosted, row: 3)
    XCTAssertEqual(names(hosted).first, "a.txt")
    XCTAssertFalse(hosted.itemList.isOpen)

    hosted.pane.shell.toggleItemList()
    hosted.pane.shell.toggleItemList()
    XCTAssertFalse(hosted.itemList.isOpen)
    XCTAssertTrue(hosted.window.firstResponder === hosted.pane.document?.surface.responder)
  }

  /// 行の × は、その文書を閉じ、一覧は開いたままでフォーカスも一覧に残る。今の文書を閉じると 1 つ前に使った文書が本体に出る。
  /// 最後の 1 つを閉じると、一覧とボタンが消える。
  func testTheCloseButtonClosesTheFileAndKeepsTheListOpen() throws {
    let hosted = try host()
    hosted.pane.toggleItemList()
    try pressMark(hosted, row: 1)
    XCTAssertEqual(names(hosted), ["b.txt", "a.txt"])
    XCTAssertTrue(hosted.pane.document === hosted.session.documents.first, "1 つ前に使った文書が本体に")
    XCTAssertTrue(hosted.itemList.isOpen, "一覧は開いたまま")
    XCTAssertTrue(hosted.pane.focusIsInItemList, "フォーカスは一覧に残る")
    XCTAssertEqual(hosted.itemList.rowCount, 3)

    try pressMark(hosted, row: 2)
    try pressMark(hosted, row: 1)
    XCTAssertTrue(names(hosted).isEmpty)
    XCTAssertFalse(hosted.itemList.isOpen, "最後の 1 つを閉じると一覧が消える")
    XCTAssertNil(hosted.pane.shell.currentItem, "ボタンも消える")
    XCTAssertTrue(hosted.window.firstResponder === hosted.pane, "本体の行き先へ")
  }

  /// 未保存の文書の × は確認を出し、キャンセルなら閉じない。「保存しない」なら閉じる。確認の間も、答えた後も、一覧は
  /// 開いたままでフォーカスも一覧にある。
  func testClosingAnUnsavedFileAsks() throws {
    let hosted = try host(["a.txt", "b.txt"])
    let a = try XCTUnwrap(hosted.session.documents.last)
    a.surface.responder.perform(Selector(("insertText:")), with: "x")
    hosted.pane.toggleItemList()
    try pressMark(hosted, row: 2)
    let sheet = try XCTUnwrap(hosted.window.attachedSheet, "確認が出る")
    XCTAssertTrue(hosted.itemList.isOpen, "確認の間も一覧は開いたまま")
    hosted.window.endSheet(sheet, returnCode: .alertThirdButtonReturn)
    XCTAssertEqual(names(hosted), ["b.txt", "a.txt"], "キャンセルなら閉じない")
    XCTAssertTrue(hosted.itemList.isOpen)
    XCTAssertTrue(hosted.pane.focusIsInItemList)

    try pressMark(hosted, row: 2)
    let again = try XCTUnwrap(hosted.window.attachedSheet)
    hosted.window.endSheet(again, returnCode: .alertSecondButtonReturn)
    XCTAssertEqual(names(hosted), ["b.txt"], "「保存しない」なら閉じる")
    XCTAssertTrue(hosted.itemList.isOpen, "閉じた後も一覧は開いたまま")
    XCTAssertTrue(hosted.pane.focusIsInItemList)
  }

  /// → で選んでいる行の詳細に入る。仮の文書には「開いたままにする」と「ファイルを閉じる」が並び、↵ で実行すると一覧へ戻る。
  /// 普通の文書には「ファイルを閉じる」だけ。
  func testTheDetailKeepsOpenOrClosesTheFile() throws {
    let hosted = try host(["a.txt", "b.txt"])
    let preview = TestScratch.caseDir.appendingPathComponent("p.txt")
    try Data("p".utf8).write(to: preview)
    try hosted.session.open(preview, as: .preview)
    hosted.session.activate(
      try XCTUnwrap(hosted.session.document(at: hosted.session.documents[1].url)))
    XCTAssertEqual(names(hosted), ["b.txt", "p.txt", "a.txt"])
    hosted.pane.toggleItemList()
    XCTAssertTrue(fileRow(hosted, 2)?.isItalic == true, "仮の文書は斜体")
    XCTAssertEqual(fileRow(hosted, 2)?.tags.count, 1, "「プレビュー」の札")

    hosted.itemList.perform(.right)
    XCTAssertEqual(hosted.itemList.rowCount, 3, "ファイルの行と、操作の行 2 つ")
    XCTAssertEqual(
      row(hosted, 1),
      .action(L10n.string(.editorOpenFilesKeepOpen, hosted.pane.localization.language)))
    hosted.itemList.perform(.enter)
    XCTAssertNil(hosted.session.preview, "普通の文書になる")
    XCTAssertNil(hosted.itemList.detail, "一覧へ戻る")
    XCTAssertEqual(hosted.itemList.selection, AnyHashable(preview.resolvingSymlinksInPath()))

    hosted.itemList.perform(.right)
    XCTAssertEqual(hosted.itemList.rowCount, 2, "普通の文書は「ファイルを閉じる」だけ")
    hosted.itemList.perform(.enter)
    XCTAssertEqual(names(hosted), ["b.txt", "a.txt"])
    XCTAssertTrue(hosted.itemList.isOpen)
    XCTAssertNil(hosted.itemList.detail)
  }

  /// 画面を切り替えると、一覧が閉じる（今の項目が無くなる）。
  func testSwitchingScreensClosesTheList() throws {
    let hosted = try host()
    hosted.pane.toggleItemList()
    hosted.pane.switchScreen(.changes)
    XCTAssertFalse(hosted.itemList.isOpen)
    XCTAssertFalse(hosted.pane.shell.isItemListOpen)
  }

  /// 一覧の行に、その文書の属するリポジトリの git の状態の字が出る（タブの worktree の外のファイルでも出る）。Orbe の
  /// 外でそのファイルを `git add` すると、開いたままの一覧の字が替わる。
  func testTheRowsShowTheGitBadgeOfTheDocumentsOwnRepository() throws {
    let home = try TempGitRepo(name: "orbe-open-files-home")
    let repo = try TempGitRepo(name: "orbe-open-files-other")
    try repo.write("n.txt", "n\n")
    let tab = TerminalTab.alone(cwd: home.root, editorSurfaces: EditorSurfaces(queriesRoot: nil))
    hostEditor(tab, width: 1000, height: 600)
    try tab.group.editor.open(repo.url("n.txt"), as: .pinned)
    tab.group.editor.selectScreen(.files)
    let pane = tab.group.view.editor
    pane.toggleItemList()
    func badge() -> GitStatus.Badge? {
      guard case .file(let file) = pane.itemList.content?.rows.row(at: 1) else { return nil }
      return file.badge
    }
    pumpMain(until: { badge() == .untracked }, "未追跡の字")
    XCTAssertTrue(repo.git(["add", "n.txt"]).isSuccess)
    pumpMain(until: { badge() == .added }, "開いたままの一覧の字が替わる")
  }

  /// ⌘P はボタンを押すのと同じ（開く・閉じる。閉じた後は本文へ）。ボタンが出ていない画面では何もしない（キーは消費する）。
  /// フォーカスが面の外（端末）にあれば受けない。端末はエディターのキーを ghostty へ素通しする。
  func testCommandPTogglesTheListLikeTheButton() throws {
    let hosted = try host()
    let commandP = NSEvent.key("p")
    XCTAssertEqual(Keybindings.chromeAction(for: commandP)?.owner, .editor)
    XCTAssertTrue(hosted.pane.performKeyEquivalent(with: commandP))
    XCTAssertTrue(hosted.itemList.isOpen)
    XCTAssertTrue(hosted.pane.performKeyEquivalent(with: commandP), "一覧にフォーカスがあっても効く")
    XCTAssertFalse(hosted.itemList.isOpen)
    XCTAssertTrue(hosted.window.firstResponder === hosted.pane.document?.surface.responder)

    hosted.pane.switchScreen(.changes)
    XCTAssertTrue(hosted.pane.performKeyEquivalent(with: commandP), "ボタンが無くてもキーは消費する")
    XCTAssertFalse(hosted.itemList.isOpen, "ボタンが出ていない画面では開かない")

    hosted.pane.switchScreen(.files)
    let outsider = NSTextField(frame: NSRect(x: 0, y: 0, width: 50, height: 20))
    hosted.tab.group.view.addSubview(outsider)
    XCTAssertTrue(hosted.window.makeFirstResponder(outsider))
    XCTAssertFalse(hosted.pane.performKeyEquivalent(with: commandP), "面の外のフォーカスには効かない")
    XCTAssertFalse(hosted.itemList.isOpen)
  }

  // MARK: - 仮の文書

  /// 今の文書が仮の文書のとき、ボタンの値は仮（名前を斜体にし、「プレビュー」の札と「開いたままにする」を出す）。
  /// 「開いたままにする」のキーの札 ↵ は、検索結果の列にフォーカスがある間だけ付き、本文や検索の入力欄にある間は付かない。
  /// 押すと普通の文書になり、フォーカスは動かない。
  func testAPreviewShowsKeepOpenWithTheReturnKeyOnlyFromTheSearchResults() throws {
    let hosted = try host(["a.txt"])
    let preview = TestScratch.caseDir.appendingPathComponent("p.txt")
    try Data("needle".utf8).write(to: preview)
    let document = try hosted.session.open(preview, as: .preview)
    hosted.window.makeFirstResponder(document.surface.responder)
    XCTAssertEqual(file(hosted)?.isPreview, true)
    XCTAssertEqual(file(hosted)?.showsKeepOpenKey, false, "本文にフォーカスがある間は札なし")

    hosted.pane.showProjectSearch(seed: nil)
    pumpMain(until: { hosted.pane.projectSearch.focusedArea == .field }, "検索の入力欄へ")
    XCTAssertEqual(file(hosted)?.showsKeepOpenKey, false, "検索の入力欄にフォーカスがある間は札なし")
    hosted.window.makeFirstResponder(hosted.pane.searchResults.list)
    pumpMain(until: { self.file(hosted)?.showsKeepOpenKey == true }, "検索結果の列にフォーカスがある間は札あり")
    hosted.window.makeFirstResponder(document.surface.responder)
    pumpMain(until: { self.file(hosted)?.showsKeepOpenKey == false }, "本文へ戻ると札なし")

    hosted.pane.shell.keepOpen()
    XCTAssertNil(hosted.session.preview, "普通の文書になる")
    XCTAssertEqual(file(hosted)?.isPreview, false, "札とボタンが消える")
    XCTAssertTrue(hosted.window.firstResponder === document.surface.responder, "フォーカスは動かない")
  }
}
