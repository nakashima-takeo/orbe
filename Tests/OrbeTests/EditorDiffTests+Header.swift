import AppKit
import OrbeEditorCore
import OrbeTestSupport
import XCTest

@testable import Orbe
@testable import OrbeEditorEngine

/// 差分のファイルの見出し——本体が diff の間だけ本体の上端に出て、diff の面と表示できない理由の一文はその下に置く。出すもの
/// （パス・状態の字・未保存・「ファイルを開く」を押せるか・確認済み）は一覧の持ち主から導き、押すと左の列と同じ操作になる。
///
/// 壊れると何が起きるか: Files の文書の上に見出しが出る・見出しが本文の先頭の行を覆う。消したファイルで「ファイルを開く」が
/// 押せる。コメントの欄で打っている間に見出しを押すと、欄から焦点が外れて空の欄が閉じる。打って未保存になっても丸が出ない。
/// 外のツールがファイルを書き換えても、見出しに「ディスクが変わった」の丸が出ない。
/// 影の上を押しても本文に届かない。
extension EditorDiffTests {
  // MARK: - 見出しの値

  private func key(_ path: String, _ kind: EditorDiff.Kind) -> EditorDiff.Key {
    EditorDiff.Key(root: "/r", path: path, kind: kind)
  }

  private func file(_ path: String, _ badge: GitStatus.Badge, opens: Bool) -> ScmChanges.File {
    ScmChanges.File(
      row: GitStatus.Row(path: path, originalPath: nil), badge: badge, opensAsFile: opens,
      discardMovesToTrash: false)
  }

  /// パスは最後の `/` でフォルダとファイル名に分かれ、Changes の状態の字と「ファイルを開く」を押せるかは、その区分の行が決める。
  /// 行が無ければ状態の字を出さず、新しい側に文書を使っていれば押せる。印の丸は作業ツリー diff だけ。
  func testTheChangesHeaderComesFromTheRow() {
    let header = DiffFileHeader(
      key("Sources/App/a.swift", .workingTree),
      facts: .changes(file("Sources/App/a.swift", .untracked, opens: true), usesDocument: true),
      mark: .diskChanged)
    XCTAssertEqual(header.folder, "Sources/App/")
    XCTAssertEqual(header.name, "a.swift")
    XCTAssertEqual(header.badge, .untracked)
    XCTAssertEqual(header.mark, .diskChanged)
    XCTAssertTrue(header.canOpenFile)
    XCTAssertNil(header.viewed, "Changes に確認済みは無い")

    let removed = DiffFileHeader(
      key("gone.txt", .staged),
      facts: .changes(
        file("gone.txt", .modified, opens: false),
        usesDocument: false), mark: .unsaved)
    XCTAssertEqual(removed.folder, "")
    XCTAssertFalse(removed.canOpenFile, "作業ツリーにファイルとして無ければ押せない")
    XCTAssertEqual(removed.mark, .none, "ステージ済み diff に印は無い")

    let rowless = DiffFileHeader(
      key("same.txt", .workingTree), facts: .changes(nil, usesDocument: true), mark: .none)
    XCTAssertNil(rowless.badge)
    XCTAssertTrue(rowless.canOpenFile)
  }

  /// PR の状態の字は追加が A でほかは M、削除されたファイルは「ファイルを開く」を押せない。変更ファイルに無ければ確認済みの
  /// 部品を出さない。
  func testThePullRequestHeaderComesFromTheChangedFiles() {
    let pr = key("a.txt", .workingTree)
    let added = DiffFileHeader(pr, facts: .pullRequest(.added, isViewed: true), mark: .unsaved)
    XCTAssertEqual(added.badge, .added)
    XCTAssertEqual(added.viewed, true)
    XCTAssertTrue(added.canOpenFile)
    let deleted = DiffFileHeader(pr, facts: .pullRequest(.deleted, isViewed: false), mark: .none)
    XCTAssertEqual(deleted.badge, .modified)
    XCTAssertFalse(deleted.canOpenFile)
    XCTAssertEqual(added.mark, .none, "PR の diff に印は無い")
    let unknown = DiffFileHeader(pr, facts: .pullRequest(nil, isViewed: false), mark: .none)
    XCTAssertNil(unknown.viewed)
    XCTAssertNil(unknown.badge)
  }

  /// ソース管理の区分の列から、パスでファイルを引く（列はパス順——同じ階層ではファイルがフォルダより先。区分が違えば
  /// 引かない）。
  func testTheChangesListFindsAFileByPath() {
    let files = ["b.txt", "z.txt", "a/b.txt", "a/c/d.txt"].map { file($0, .modified, opens: true) }
    let changes = ScmChanges(staged: [], changes: files, head: nil, stagedVersions: [:])
    for path in ["a/b.txt", "a/c/d.txt", "b.txt", "z.txt"] {
      XCTAssertEqual(changes.file(in: .changes, path: path)?.path, path)
    }
    XCTAssertNil(changes.file(in: .changes, path: "a.txt"))
    XCTAssertNil(changes.file(in: .staged, path: "b.txt"))
  }

  // MARK: - 本体の上端

  /// 見出しは diff の本体の間だけ出て、diff の面はその下から始まる。Files の文書と空の本体には出ない。
  func testTheHeaderSitsAboveTheDiffOnly() throws {
    try repo.write("a.txt", "one\nTWO\nthree\nfour\n")
    let (tab, _) = tab()
    let pane = tab.group.view.editor
    let diff = try tab.group.editor.openDiff(id("a.txt", .workingTree))
    tab.group.editor.selectScreen(.changes)
    waitRows(diff, "変更が出る") { !$0.isEmpty }
    pane.layoutSubtreeIfNeeded()
    XCTAssertFalse(pane.headerHost.isHidden)
    XCTAssertEqual(pane.headerHost.rootView.subject?.key, diff.id)
    let surface = try engine(diff.newSurface)
    XCTAssertEqual(surface.view.frame.minY, pane.bodyRect.minY + Theme.Layout.editorDiffHeader)
    XCTAssertEqual(surface.view.frame.maxY, pane.bodyRect.maxY)

    tab.group.editor.selectScreen(.files)
    pane.layoutSubtreeIfNeeded()
    XCTAssertTrue(pane.headerHost.isHidden, "空の Files")
    let document = try tab.group.editor.open(repo.url("a.txt"), as: .pinned)
    pane.layoutSubtreeIfNeeded()
    XCTAssertTrue(pane.headerHost.isHidden, "文書")
    XCTAssertEqual(document.surface.view.frame.minY, pane.bodyRect.minY)
  }

  /// 帯の下の影の上を押すと、見出しではなく下の面に届く。
  func testThePressBelowTheHeaderReachesTheSurface() throws {
    try repo.write("a.txt", "one\nTWO\nthree\nfour\n")
    let (tab, _) = tab()
    let pane = tab.group.view.editor
    let diff = try tab.group.editor.openDiff(id("a.txt", .workingTree))
    tab.group.editor.selectScreen(.changes)
    waitRows(diff, "変更が出る") { !$0.isEmpty }
    pane.layoutSubtreeIfNeeded()
    let body = pane.bodyRect
    let onBar = pane.belowBar.hitTest(NSPoint(x: body.midX, y: body.minY + 10))
    XCTAssertTrue(onBar?.isDescendant(of: pane.headerHost) == true, "帯の上は見出し")
    let onShadow = pane.belowBar.hitTest(
      NSPoint(x: body.midX, y: body.minY + Theme.Layout.editorDiffHeader + 4))
    XCTAssertTrue(
      onShadow?.isDescendant(of: try engine(diff.newSurface).view) == true, "影の上は面")
  }

  /// 打って未保存になると見出しに未保存の丸が出て、保存すると消える。
  func testTheHeaderShowsTheUnsavedDot() throws {
    try repo.write("a.txt", "one\nTWO\nthree\nfour\n")
    let (tab, window) = tab()
    let pane = tab.group.view.editor
    let diff = try tab.group.editor.openDiff(id("a.txt", .workingTree))
    tab.group.editor.selectScreen(.changes)
    waitRows(diff, "変更が出る") { !$0.isEmpty }
    let surface = try engine(diff.newSurface)
    window.makeFirstResponder(surface.responder)
    XCTAssertEqual(pane.headerHost.rootView.subject?.mark, EditorItemListRow.Mark.none)
    surface.selectedRange = NSRange(location: 0, length: 0)
    surface.responder.perform(#selector(NSResponder.insertText(_:)), with: "Z")
    pumpMain(until: { pane.headerHost.rootView.subject?.mark == .unsaved }, "未保存の丸が出る")
    XCTAssertTrue(pane.performKeyEquivalent(with: .key("s")))
    pumpMain(
      until: { pane.headerHost.rootView.subject?.mark == EditorItemListRow.Mark.none }, "保存で消える")
  }

  /// 未保存の文書のファイルを外のツールが書き換えると、見出しの丸は「ディスクが変わった」に替わる（未保存より優先）。上書きの
  /// 保存で消える。
  func testTheHeaderShowsTheDiskChangedDot() throws {
    try repo.write("a.txt", "one\nTWO\nthree\nfour\n")
    let (tab, window) = tab()
    let pane = tab.group.view.editor
    let diff = try tab.group.editor.openDiff(id("a.txt", .workingTree))
    tab.group.editor.selectScreen(.changes)
    waitRows(diff, "変更が出る") { !$0.isEmpty }
    let surface = try engine(diff.newSurface)
    let document = try XCTUnwrap(diff.document)
    window.makeFirstResponder(surface.responder)
    surface.selectedRange = NSRange(location: 0, length: 0)
    surface.responder.perform(#selector(NSResponder.insertText(_:)), with: "Z")
    pumpMain(until: { pane.headerHost.rootView.subject?.mark == .unsaved }, "前提: 未保存の丸")

    try repo.write("a.txt", "theirs\n")
    document.reconcileWithDisk()
    pumpMain(
      until: { pane.headerHost.rootView.subject?.mark == .diskChanged }, "ディスクが変わったの丸に替わる")
    try document.save(force: true)
    pumpMain(
      until: { pane.headerHost.rootView.subject?.mark == EditorItemListRow.Mark.none }, "上書きで消える")
  }

  /// 「ファイルを開く」は、そのファイルを普通の文書として Files の画面で開き、本文に焦点を移す。
  func testOpenFileShowsTheDocumentInFiles() throws {
    try repo.write("a.txt", "one\nTWO\nthree\nfour\n")
    let (tab, window) = tab()
    let pane = tab.group.view.editor
    let diff = try tab.group.editor.openDiff(id("a.txt", .workingTree))
    tab.group.editor.selectScreen(.changes)
    waitRows(diff, "変更が出る") { !$0.isEmpty }
    pane.openHeaderFile()
    XCTAssertEqual(tab.group.editor.screen, .files)
    let document = try XCTUnwrap(pane.document)
    XCTAssertEqual(document.url, repo.url("a.txt").resolvingSymlinksInPath())
    XCTAssertNil(tab.group.editor.preview, "仮の文書ではない")
    pumpMain(until: { window.firstResponder === document.surface.responder }, "本文に焦点")
  }

  /// 新しいコメントの欄に焦点があるまま見出しのチェックを押すと、確認済みが付き、焦点は欄に残る（空の欄も閉じない）。
  func testPressingTheHeaderCheckKeepsTheFocusInTheCommentField() throws {
    let (diff, tab) = try commentedTab(Remote())
    let pane = tab.group.view.editor
    guard case .pullRequest(let state) = diff.id.kind else { return XCTFail("前提: PR の diff") }
    let window = try XCTUnwrap(pane.window)
    placeOffscreen(window)
    let surface = try engine(diff.newSurface)
    window.makeFirstResponder(surface.responder)
    let layer = try XCTUnwrap(diff.comments)
    layer.surface(surface, didMarkFrom: .document(1), to: .document(1))
    let draft = try XCTUnwrap(layer.draft(at: .at(.new, 1)))

    let body = pane.bodyRect
    try click(
      pane,
      at: NSPoint(
        x: body.minX + Theme.Layout.editorDiffHeaderLeadingPullRequest
          + Theme.Layout.editorPrCheckbox / 2,
        y: body.minY + Theme.Layout.editorDiffHeader / 2))
    pumpMain(until: { state.isViewed("a.txt") }, "確認済みが付く")
    XCTAssertTrue(window.firstResponder === surface.responder, "焦点は面のまま")
    XCTAssertEqual(surface.primary, .field(draft.field.id), "欄が主のまま")
    XCTAssertIdentical(layer.draft(at: .at(.new, 1)), draft, "空の欄は閉じない")
  }
}
