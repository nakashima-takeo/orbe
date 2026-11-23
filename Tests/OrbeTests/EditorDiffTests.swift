import AppKit
import OrbeEditorCore
import OrbeTestSupport
import XCTest

@testable import Orbe
@testable import OrbeEditorEngine

/// diff——作業ツリー（index の版 ↔ 文書）とステージ済み（HEAD の版 ↔ index の版）の側と並び、片側だけの diff、
/// 表示できない理由、git と外の書き換えへの追従、インライン / 並列の面。壊れると、diff の削除行が古い版の別の行を指す・
/// ステージ済みの rename が元のパスの版で比べられない・git add しても diff が古いまま・並列の 2 面が揃わない・大きな
/// ファイルの離れた変更が 1 つの区間にまとまる・ほかのファイルが次々に変わる間、ステージ済み diff の中身が届かない。
@MainActor
final class EditorDiffTests: OrbeTestCase {
  var repo: TempGitRepo!

  override func setUpWithError() throws {
    try XCTSkipIf(RenderThread.device == nil, "Metal の装置が無い環境では面を作らない")
    repo = try TempGitRepo()
    try repo.write("a.txt", "one\ntwo\nthree\nfour\n")
    XCTAssertTrue(repo.git(["add", "-A"]).isSuccess)
    XCTAssertTrue(repo.git(["commit", "-qm", "four lines"]).isSuccess)
  }

  /// 根のタブを窓に載せる。タブ（連とセッション）は、製品で workspace が持つのと同じく、このテストがテストの終わりまで持つ——
  /// pane は連が生きている間だけ本体を見せるので、呼び手がタブを捨てても diff と文書の持ち主が残る。
  /// 窓の幅は `width`。左の列は開いているので、既定の 900 なら diff はインライン、`sideWidth` なら並列で出る。
  func tab(width: CGFloat = 900, height: CGFloat = 400) -> (TerminalTab, NSWindow) {
    let tab = TerminalTab.alone(cwd: repo.root, editorSurfaces: EditorSurfaces(queriesRoot: nil))
    let window = hostEditor(tab, width: width, height: height)
    tab.group.view.editor.configure(
      translucency: ChromeTranslucency(), localization: LocalizationStore(language: .ja),
      fontResolver: ChromeFontResolver(), sidebar: EditorSidebarState())
    addTeardownBlock { withExtendedLifetime(tab) {} }
    return (tab, window)
  }

  /// 左の列を既定の幅で開いて、本体の幅がちょうど並列の境の値になる窓の幅。
  static let sideWidth =
    Theme.Layout.editorDiffSideWidth + Theme.Layout.editorSidebar + Theme.Stroke.hairline

  /// 窓の幅を `width` にして配置する（本体の幅が変わり、見せ方が決まり直す）。
  func resize(_ window: NSWindow, width: CGFloat) {
    window.setContentSize(NSSize(width: width, height: window.frame.height))
    window.contentView?.layoutSubtreeIfNeeded()
  }

  func id(_ path: String, _ kind: EditorDiff.Kind) -> EditorDiff.Key {
    EditorDiff.Key(root: repo.root, path: path, kind: kind)
  }

  func engine(_ surface: (any TextSurface)?) throws -> MetalTextSurface {
    try XCTUnwrap(surface as? MetalTextSurface)
  }

  /// 見せている diff の並びが `ready` を満たすまで待つ。
  func waitRows(
    _ diff: EditorDiff, _ message: String, file: StaticString = #filePath, line: UInt = #line,
    _ ready: (RowLayout) -> Bool
  ) {
    pumpMain(
      until: {
        guard let surface = diff.newSurface as? MetalTextSurface else { return false }
        return diff.content == .ready && ready(surface.rows)
      }, message, file: file, line: line)
  }

  func removedLines(_ rows: RowLayout) -> [Int] {
    rows.contents.flatMap { content -> [Int] in
      guard case .lines(let lines) = content else { return [] }
      return lines.compactMap(\.line)
    }
  }

  // MARK: - 作業ツリー

  /// 作業ツリー diff は index の版 ↔ 文書。インラインでは削除行が古い側（index の本文）の行を指す差し込みになり、追加の
  /// 区間に型が付く。新しい側の面は開いている文書と同じ文書の面で、Files の画面でその文書に戻ればコードの見え方に戻る。
  /// diff は開いている文書の列に入らず、同じ diff をもう一度開いても開き直さない。
  func testAWorkingTreeDiffShowsTheIndexAgainstTheDocument() throws {
    try repo.write("a.txt", "one\nTWO\nthree\nfour\nfive\n")
    let (tab, _) = tab()
    let pane = tab.group.view.editor
    let document = try tab.group.editor.open(repo.url("a.txt"), as: .pinned)
    let diff = try tab.group.editor.openDiff(id("a.txt", .workingTree))
    XCTAssertTrue(diff.document === document, "開いている文書と同じ文書")
    XCTAssertTrue(pane.diff === diff, "本体は diff")
    waitRows(diff, "並びが届く") { !$0.isEmpty }
    XCTAssertEqual(diff.old?.text.contiguousUnits().count, "one\ntwo\nthree\nfour\n".utf16.count)
    let surface = try engine(diff.newSurface)
    XCTAssertTrue(surface === document.surface as? MetalTextSurface)
    XCTAssertEqual(removedLines(surface.rows), [1], "削除行は古い側の行 2 を指す")
    XCTAssertEqual(surface.rows.boundaries, [1])
    XCTAssertEqual(surface.rows.style(ofLine: 1), DiffStyle.added)
    XCTAssertNil(surface.rows.style(ofLine: 2))
    XCTAssertEqual(surface.rows.style(ofLine: 4), DiffStyle.added)
    XCTAssertEqual(surface.presentation, DiffStyle.inline)
    XCTAssertTrue(pane.focusTarget === surface.responder, "焦点の行き先は diff の面")
    XCTAssertEqual(
      tab.group.editor.documents.map(\.url.lastPathComponent), ["a.txt"],
      "diff は開いている文書の列に入らない")

    XCTAssertTrue(try tab.group.editor.openDiff(id("a.txt", .workingTree)) === diff, "開き直さない")

    tab.group.editor.show(document)
    XCTAssertTrue(pane.document === document)
    XCTAssertTrue(surface.rows.isEmpty, "文書の本体ではコードの見え方")
    XCTAssertEqual(surface.presentation, .code)
  }

  /// diff の間は、ガターなら 1 つの区間にまとめる大きさでも、離れた変更を行ごとに出す。文書の本体へ戻れば、ガターは
  /// 同じ変更を 1 つの区間にまとめる（打鍵ごとの手間を抑える上限に戻る）。
  func testADiffShowsDistantChangesLineByLineBeyondTheGutterLimit() throws {
    var lines = (0..<(LineDiff.maximumComparedLines + 200)).map { "line \($0)" }
    try repo.write("long.txt", lines.joined(separator: "\n") + "\n")
    XCTAssertTrue(repo.git(["add", "-A"]).isSuccess)
    XCTAssertTrue(repo.git(["commit", "-qm", "long"]).isSuccess)
    lines[0] = "changed first"
    lines[lines.count - 1] = "changed last"
    try repo.write("long.txt", lines.joined(separator: "\n") + "\n")
    let (tab, _) = tab()
    let document = try tab.group.editor.open(repo.url("long.txt"), as: .pinned)
    let diff = try tab.group.editor.openDiff(id("long.txt", .workingTree))
    waitRows(diff, "離れた 2 か所だけが変更") { self.removedLines($0) == [0, lines.count - 1] }

    tab.group.editor.show(document)
    pumpMain(until: { document.hunksAreCurrent && document.hunks.count == 1 }, "ガターは 1 つの区間")
  }

  /// 中身が届く前に本体（pane）にあった焦点は、面ができたときに面へ移る。
  func testTheFocusMovesToTheDiffSurfaceWhenItArrives() throws {
    try repo.write("a.txt", "changed\n")
    let (tab, window) = tab()
    let pane = tab.group.view.editor
    window.makeFirstResponder(pane)
    let diff = try tab.group.editor.openDiff(id("a.txt", .workingTree))
    waitRows(diff, "並びが届く") { !$0.isEmpty }
    pumpMain(until: { window.firstResponder === diff.newSurface?.responder }, "焦点は面へ")
  }

  /// 未追跡のファイルは全部の行（改行で終わる本文の末尾の空の行も）が追加、作業ツリーで消したファイルは全部の行が削除になる。
  /// 版が無い側の面は、エディターの都合で持つ空の行に番号を描かない。
  func testOneSidedWorkingTreeDiffs() throws {
    try repo.write("new.txt", "x\ny\n")
    let (tab, _) = tab()
    let added = try tab.group.editor.openDiff(id("new.txt", .workingTree))
    waitRows(added, "未追跡は全部が追加") {
      $0.style(ofLine: 0) == DiffStyle.added && $0.style(ofLine: 2) == DiffStyle.added
    }
    XCTAssertTrue(try engine(added.newSurface).rows.isEmpty, "− 空の行は出ない")
    XCTAssertTrue(try engine(added.newSurface).presentation.numbersOwnLines)
    try FileManager.default.removeItem(at: repo.url("a.txt"))
    let removed = try tab.group.editor.openDiff(id("a.txt", .workingTree))
    waitRows(removed, "消したファイルは全部が削除") { self.removedLines($0) == [0, 1, 2, 3, 4] }
    XCTAssertNil(removed.document, "新しい側の文書は無い")
    XCTAssertFalse(
      try engine(removed.newSurface).presentation.numbersOwnLines, "存在しない行に番号を描かない")
  }

  /// 先頭の行から始まる最初の変更区間は、文書の先頭から見せる——先頭の行の前に差し込んだ削除行が見えている高さより長く
  /// ても、その頭が上へ外れない（消したファイルは全部の行がこの形）。
  func testAChangeFromTheFirstLineOpensAtTheTopOfTheDocument() throws {
    let lines = (0..<200).map { "line \($0)" }
    try repo.write("gone.txt", lines.joined(separator: "\n") + "\n")
    try repo.write("head.txt", lines.joined(separator: "\n") + "\n")
    XCTAssertTrue(repo.git(["add", "-A"]).isSuccess)
    XCTAssertTrue(repo.git(["commit", "-qm", "long"]).isSuccess)
    try FileManager.default.removeItem(at: repo.url("gone.txt"))
    try repo.write("head.txt", lines[100...].joined(separator: "\n") + "\n")
    let (tab, _) = tab()
    for path in ["gone.txt", "head.txt"] {
      let diff = try tab.group.editor.openDiff(id(path, .workingTree))
      waitRows(diff, "\(path): 削除行が届く") { !self.removedLines($0).isEmpty }
      pumpMain(until: { diff.placement == .placed }, "\(path): 最初の変更区間へ送る")
      let surface = try engine(diff.newSurface)
      surface.flush()
      XCTAssertLessThan(surface.viewportLines.visible, 100, "前提: 削除行は見えている高さより長い")
      XCTAssertEqual(surface.viewportLines.first, 0, "\(path): 削除行の頭から見える")
    }
  }

  /// ステージ済みの新しいファイル・消したファイルも、版が無い側を 0 行として全部の行が追加・削除になる——存在しない空の行は
  /// 出ず、並列の無い側は詰め物だけで、番号を描かない。
  func testOneSidedStagedDiffsShowNoLineThatDoesNotExist() throws {
    try repo.write("n.txt", "aaa")
    XCTAssertTrue(repo.git(["add", "n.txt"]).isSuccess)
    XCTAssertTrue(repo.git(["rm", "-q", "a.txt"]).isSuccess)
    let (tab, window) = tab()
    let added = try tab.group.editor.openDiff(id("n.txt", .staged))
    waitRows(added, "+ aaa") { $0.style(ofLine: 0) == DiffStyle.added }
    XCTAssertEqual(removedLines(try engine(added.newSurface).rows), [], "− 空の行は出ない")
    let removed = try tab.group.editor.openDiff(id("a.txt", .staged))
    waitRows(removed, "全部の行が削除") { self.removedLines($0) == [0, 1, 2, 3, 4] }
    XCTAssertFalse(try engine(removed.newSurface).presentation.numbersOwnLines)

    let reopened = try tab.group.editor.openDiff(id("n.txt", .staged))
    waitRows(reopened, "+ aaa") { $0.style(ofLine: 0) == DiffStyle.added }
    resize(window, width: Self.sideWidth)
    pumpMain(until: { reopened.oldSurface != nil }, "並列")
    let left = try engine(reopened.oldSurface)
    let pads = left.rows.contents.flatMap { content -> [InsertedLine] in
      guard case .lines(let lines) = content else { return [] }
      return lines.filter { $0.line == nil }
    }
    XCTAssertEqual(pads.count, 1, "左は + aaa に並ぶ詰め物だけ")
    XCTAssertEqual(left.rows.style(ofLine: 0), nil, "左の空の行は削除ではない")
    XCTAssertFalse(left.presentation.numbersOwnLines, "左の空の行に番号を描かない")
    XCTAssertTrue(try engine(reopened.newSurface).presentation.numbersOwnLines)
  }

  /// バイナリ・シンボリックリンク・追跡中のファイルを置き換えたディレクトリ・競合中は、diff は開き、本体に理由の一文が出る。
  func testUnavailableDiffsShowAReason() throws {
    try Data([0xFF, 0xFE, 0x00, 0x01]).write(to: repo.url("bin.dat"))
    try repo.write("d.txt", "d\n")
    XCTAssertTrue(repo.git(["add", "bin.dat", "d.txt"]).isSuccess)
    try FileManager.default.removeItem(at: repo.url("d.txt"))
    try repo.write("d.txt/inner.txt", "x\n")
    try FileManager.default.createSymbolicLink(
      atPath: repo.url("link.txt").path, withDestinationPath: "a.txt")
    let (tab, _) = tab()
    let pane = tab.group.view.editor
    let binary = try tab.group.editor.openDiff(id("bin.dat", .workingTree))
    pumpMain(until: { binary.content == .unavailable(.notText) }, "バイナリ")
    pumpMain(until: { pane.faceContent == .notice(.editorDiffNotText) && !pane.faceHost.isHidden })
    let link = try tab.group.editor.openDiff(id("link.txt", .workingTree))
    pumpMain(until: { link.content == .unavailable(.symlink) }, "シンボリックリンク")
    XCTAssertTrue(pane.focusTarget === pane, "面が無ければ行き先は pane")
    try tab.group.editor.openDiff(id("d.txt", .workingTree))
    pumpMain(until: { pane.faceContent == .notice(.editorDiffDirectory) }, "ディレクトリ")

    XCTAssertTrue(repo.git(["checkout", "-qb", "other"]).isSuccess)
    try repo.write("a.txt", "other\n")
    XCTAssertTrue(repo.git(["commit", "-qam", "other"]).isSuccess)
    XCTAssertTrue(repo.git(["checkout", "-q", "main"]).isSuccess)
    try repo.write("a.txt", "main\n")
    XCTAssertTrue(repo.git(["commit", "-qam", "main"]).isSuccess)
    XCTAssertFalse(repo.git(["merge", "other"]).isSuccess, "前提: 競合する")
    let conflicted = try tab.group.editor.openDiff(id("a.txt", .staged))
    pumpMain(until: { conflicted.content == .unavailable(.conflicted) }, "競合中")
  }

  // MARK: - ステージ済み

  /// ステージ済み diff は HEAD の版 ↔ index の版で、rename なら古い側は元のパスの HEAD の版。同じパスの作業ツリー diff は
  /// 別の diff で、開けば Changes の diff が入れ替わる。
  func testAStagedRenameComparesTheOriginalPathsHeadVersion() throws {
    XCTAssertTrue(repo.git(["mv", "a.txt", "b.txt"]).isSuccess)
    try repo.write("b.txt", "one\ntwo\nthree\nfour\nfive\n")
    XCTAssertTrue(repo.git(["add", "b.txt"]).isSuccess)
    let (tab, _) = tab()
    let staged = try tab.group.editor.openDiff(id("b.txt", .staged))
    waitRows(staged, "追加の 1 行") { $0.style(ofLine: 4) == DiffStyle.added }
    XCTAssertEqual(staged.old?.text.lineCount, 5, "古い側は a.txt の HEAD の版")
    XCTAssertEqual(staged.newRevision?.text.lineCount, 6)
    XCTAssertTrue(try engine(staged.newSurface).rows.boundaries.isEmpty, "削除行は無い")
    let working = try tab.group.editor.openDiff(id("b.txt", .workingTree))
    XCTAssertFalse(working === staged)
    XCTAssertTrue(tab.group.editor.changesDiff === working)
  }

  // MARK: - 並列

  /// 並列は古い側の面と新しい側の面を左右に並べてスクロールを共にし、インラインへ戻せば古い側の面は閉じる。切り替えても
  /// 見えている先頭の新しい側の行は保たれ、選んだ見せ方は全部の diff に効く。
  func testSideBySideSharesTheScrollAndSwitchingKeepsTheFirstVisibleLine() throws {
    let lines = (0..<200).map { "line \($0)" }
    try repo.write("long.txt", lines.joined(separator: "\n") + "\n")
    XCTAssertTrue(repo.git(["add", "-A"]).isSuccess)
    XCTAssertTrue(repo.git(["commit", "-qm", "long"]).isSuccess)
    var changed = lines
    changed[120] = "changed 120"
    changed.insert(contentsOf: ["added a", "added b"], at: 150)
    try repo.write("long.txt", changed.joined(separator: "\n") + "\n")
    let (tab, window) = tab()
    let pane = tab.group.view.editor
    let diff = try tab.group.editor.openDiff(id("long.txt", .workingTree))
    waitRows(diff, "インライン") { !$0.isEmpty }
    let right = try engine(diff.newSurface)
    right.flush()
    let first = right.viewport.top
    XCTAssertGreaterThan(first.line, 0, "最初の変更区間へ送られている")

    resize(window, width: Self.sideWidth)
    pumpMain(until: { diff.oldSurface != nil && diffSurfaceCount(pane) == 2 }, "並列の 2 面")
    weak var closed: MetalTextSurface?
    try {
      let left = try engine(diff.oldSurface)
      closed = left
      XCTAssertTrue(left.partner === right, "スクロールを共にする")
      XCTAssertEqual(right.presentation, DiffStyle.side)
      XCTAssertEqual(left.rows.style(ofLine: 120), DiffStyle.removed)
      XCTAssertEqual(right.rows.style(ofLine: 150), DiffStyle.added)
      right.flush()
      XCTAssertEqual(right.viewport.top, first, "見えている先頭の行は保たれる")
      XCTAssertEqual(left.view.frame.maxX + 1, right.view.frame.minX, "境の線 1px を挟む")
    }()

    resize(window, width: Self.sideWidth - 1)
    pumpMain(until: { diff.oldSurface == nil && closed == nil }, "古い側の面は閉じる")
    XCTAssertNil(right.partner, "共有が外れる")
    XCTAssertEqual(right.presentation, DiffStyle.inline)
    right.flush()
    XCTAssertEqual(right.viewport.top, first)
  }

  private func diffSurfaceCount(_ pane: EditorPaneView) -> Int {
    pane.diff.map { pane.diffSurfaces($0).count } ?? 0
  }

  // MARK: - 文書の持ち主

  /// diff の中で編集して未保存にした文書は開いている文書の列に入る。そのタブを × で閉じると必ず確認が出て、「保存しない」
  /// なら文書を捨て、Changes の diff は同じ対象で開き直して編集前の中身（ディスクの姿）に戻る。
  func testClosingAnUnsavedDocumentAsksAndDiscardingReopensTheDiff() throws {
    try repo.write("a.txt", "changed\n")
    let (tab, window) = tab()
    let pane = tab.group.view.editor
    let diff = try tab.group.editor.openDiff(id("a.txt", .workingTree))
    let document = try XCTUnwrap(diff.document)
    XCTAssertTrue(tab.group.editor.documents.isEmpty, "前提: 未保存でなければ列に入らない")
    document.surface.responder.perform(Selector(("insertText:")), with: "Z")
    XCTAssertTrue(tab.group.editor.documents.map(\.url) == [document.url], "未保存になると列に入る")
    XCTAssertEqual(tab.group.editor.documents.map(\.isDirty), [true], "列の文書が未保存")
    XCTAssertEqual(tab.group.unsavedDocuments().count, 1, "閉じれば失われる文書に数える")

    pane.requestClose(document.url)
    let sheet = try XCTUnwrap(window.attachedSheet, "必ず確認")
    window.endSheet(sheet, returnCode: .alertSecondButtonReturn)
    XCTAssertTrue(tab.group.editor.documents.isEmpty)
    let reopened = try XCTUnwrap(tab.group.editor.changesDiff)
    XCTAssertFalse(reopened === diff, "同じ対象で開き直す")
    XCTAssertEqual(reopened.id, diff.id)
    XCTAssertFalse(reopened.document === document, "捨てた文書は使わない")
    XCTAssertEqual(reopened.document.map { bodyText($0) }, "changed\n", "編集前の中身")
  }

  /// 未保存の文書を diff が使っているときに作業ツリーのファイルが消えても、文書は手放さず（閉じれば失われる文書に数えた
  /// まま）、diff の新しい側に残る。
  func testAnUnsavedDocumentADiffUsesOutlivesTheFile() throws {
    let (tab, _) = tab()
    let document = try tab.group.editor.open(repo.url("a.txt"), as: .pinned)
    document.surface.responder.perform(Selector(("insertText:")), with: "Z")
    let diff = try tab.group.editor.openDiff(id("a.txt", .workingTree))
    waitRows(diff, "変更が出る") { !$0.isEmpty }
    try FileManager.default.removeItem(at: repo.url("a.txt"))
    // status は、消えたことの知らせ（diff が作業ツリーを読み直すきっかけ）の後に取り直される。
    pumpMain(until: { diff.files.status?.entries["a.txt"]?.unstaged == .deleted }, "消えた")
    XCTAssertTrue(diff.document === document)
    XCTAssertEqual(tab.group.unsavedDocuments().count, 1, "閉じれば失われる文書に数える")
  }

  // MARK: - 永続と現在地

  /// diff は永続に書かない。Changes の画面で diff を出していても、書くのは開いている文書の列と今の文書と選んだ画面。現在地は
  /// 根だけ。
  func testDiffsAreNotPersistedAndTheLocationIsTheRoot() throws {
    try repo.write("b.txt", "b\n")
    let (tab, _) = tab()
    try tab.group.editor.open(repo.url("b.txt"), as: .pinned)
    try tab.group.editor.openDiff(id("a.txt", .workingTree))
    try tab.group.editor.open(repo.url("a.txt"), as: .pinned)
    tab.group.editor.selectScreen(.changes)
    let documents = try XCTUnwrap(tab.group.groupState()?.editor.documents)
    XCTAssertEqual(documents.open, [repo.url("b.txt").path, repo.url("a.txt").path])
    XCTAssertEqual(documents.active, repo.url("a.txt").path)
    XCTAssertEqual(tab.group.groupState()?.editor.screen, .changes)
    XCTAssertEqual(tab.group.editorLocation, .root(repo.root))
  }
}

extension EditorDiff {
  /// diff の根のサービス（テストの略記。出どころが握っている間は同じもの）。
  var files: RootFiles { RootFiles.shared(for: id.root) }
  /// 根のサービスの知らせを受ける出どころ（テストの略記。作業ツリーとステージ済み）。
  var rootObserver: RootFilesObserver? { source as? RootFilesObserver }
  /// 作業ツリー diff の出どころ（テストの略記）。
  var workingTree: EditorDiffWorkingTree? { source as? EditorDiffWorkingTree }
}
