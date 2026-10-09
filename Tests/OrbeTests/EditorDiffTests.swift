import AppKit
import OrbeEditorCore
import OrbeTestSupport
import XCTest

@testable import Orbe
@testable import OrbeEditorEngine

/// diff のタブ——作業ツリー（index の版 ↔ 文書）とステージ済み（HEAD の版 ↔ index の版）の側と並び、片側だけの diff、
/// 表示できない理由、git と外の書き換えへの追従、インライン / 並列の面。壊れると、diff の削除行が古い版の別の行を指す・
/// ステージ済みの rename が元のパスの版で比べられない・git add しても diff が古いまま・並列の 2 面が揃わない。
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

  private func tab() -> (TerminalTab, NSWindow) {
    let tab = TerminalTab(cwd: repo.root, editorSurfaces: EditorSurfaces(queriesRoot: nil))
    let window = hostEditor(tab, width: 900)
    tab.view.editor.configure(
      translucency: ChromeTranslucency(), localization: LocalizationStore(language: .ja),
      fontResolver: ChromeFontResolver(), sidebar: EditorSidebarState(),
      diffModes: EditorDiffModeState())
    addTeardownBlock { window.orderOut(nil) }
    return (tab, window)
  }

  private func id(_ path: String, _ kind: EditorDiff.Kind) -> EditorDiff.Key {
    EditorDiff.Key(root: repo.root, path: path, kind: kind)
  }

  private func engine(_ surface: (any TextSurface)?) throws -> MetalTextSurface {
    try XCTUnwrap(surface as? MetalTextSurface)
  }

  /// 見せている diff の並びが `ready` を満たすまで待つ。
  private func waitRows(
    _ diff: EditorDiff, _ message: String, file: StaticString = #filePath, line: UInt = #line,
    _ ready: (RowLayout) -> Bool
  ) {
    pumpMain(
      until: {
        guard let surface = diff.newSurface as? MetalTextSurface else { return false }
        return diff.content == .ready && ready(surface.rows)
      }, message, file: file, line: line)
  }

  private func removedLines(_ rows: RowLayout) -> [Int] {
    rows.contents.flatMap { content -> [Int] in
      guard case .lines(let lines) = content else { return [] }
      return lines.compactMap(\.line)
    }
  }

  // MARK: - 作業ツリー

  /// 作業ツリー diff は index の版 ↔ 文書。インラインでは削除行が古い側（index の本文）の行を指す差し込みになり、追加の
  /// 区間に型が付く。新しい側の面はファイルタブと同じ文書の面で、diff の間は読むだけ、ファイルタブに戻れば編集できる。
  /// 同じ diff をもう一度開いてもタブは増えない。
  func testAWorkingTreeDiffShowsTheIndexAgainstTheDocument() throws {
    try repo.write("a.txt", "one\nTWO\nthree\nfour\nfive\n")
    let (tab, _) = tab()
    let pane = tab.view.editor
    let document = try tab.editor.open(repo.url("a.txt"), as: .pinned)
    let diff = try tab.editor.openDiff(id("a.txt", .workingTree), as: .pinned)
    XCTAssertTrue(diff.document === document, "ファイルタブと同じ文書")
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
    XCTAssertFalse(surface.isEditable, "diff の間は読むだけ")
    XCTAssertEqual(surface.presentation, DiffStyle.inline)
    XCTAssertTrue(pane.focusTarget === surface.responder, "焦点の行き先は diff の面")
    XCTAssertEqual(pane.shell.tabs.map(\.diffKind), [nil, .workingTree])

    try tab.editor.openDiff(id("a.txt", .workingTree), as: .pinned)
    XCTAssertEqual(tab.editor.tabs.count, 2, "同じ diff はタブを増やさない")

    tab.editor.activate(document)
    XCTAssertTrue(pane.document === document)
    XCTAssertTrue(surface.isEditable, "ファイルタブではコードの見え方")
    XCTAssertTrue(surface.rows.isEmpty)
    XCTAssertEqual(surface.presentation, .code)
    XCTAssertEqual(document.hunkLimit, LineDiff.gutter, "ガターの上限に戻る")
  }

  /// 中身が届く前に本体（pane）にあった焦点は、面ができたときに面へ移る。
  func testTheFocusMovesToTheDiffSurfaceWhenItArrives() throws {
    try repo.write("a.txt", "changed\n")
    let (tab, window) = tab()
    let pane = tab.view.editor
    window.makeFirstResponder(pane)
    let diff = try tab.editor.openDiff(id("a.txt", .workingTree), as: .pinned)
    waitRows(diff, "並びが届く") { !$0.isEmpty }
    pumpMain(until: { window.firstResponder === diff.newSurface?.responder }, "焦点は面へ")
  }

  /// diff を開いたまま git add すれば作業ツリー diff は変化なしになり、外のツールが書けば追従する。並びの差し込みは古い側の
  /// 本文とずれない（底と並びを一緒に入れ替える）。
  func testAWorkingTreeDiffFollowsTheIndexAndExternalWrites() throws {
    try repo.write("a.txt", "one\nTWO\nthree\nfour\n")
    let (tab, _) = tab()
    let diff = try tab.editor.openDiff(id("a.txt", .workingTree), as: .pinned)
    waitRows(diff, "変更が出る") { !$0.isEmpty }
    XCTAssertTrue(repo.git(["add", "a.txt"]).isSuccess)
    waitRows(diff, "ステージすれば作業ツリーの変更は無い") { $0.isEmpty && $0.spans.allSatisfy { $0.style == nil } }
    try repo.write("a.txt", "one\nTWO\nthree\n")
    waitRows(diff, "外の書き換えで消えた行が削除行になる") { self.removedLines($0) == [3] }
    let old = try XCTUnwrap(diff.old)
    XCTAssertEqual(old.text.lineCount, 5, "古い側はステージした本文")
  }

  /// ファイルタブで編集してから diff タブへ戻ると、戻ったその時から削除行は編集で動いた本文の行に付いていて（離れていた
  /// 間の古い並びを置かない）、編集は diff に出る。
  func testEditsInTheFileTabShowInTheDiffOnComingBack() throws {
    try repo.write("a.txt", "one\nTWO\nthree\nfour\n")
    let (tab, _) = tab()
    let document = try tab.editor.open(repo.url("a.txt"), as: .pinned)
    let diff = try tab.editor.openDiff(id("a.txt", .workingTree), as: .pinned)
    waitRows(diff, "変更が出る") { $0.boundaries == [1] }
    tab.editor.activate(document)
    let responder = document.surface.responder
    responder.perform(#selector(NSResponder.moveToBeginningOfDocument(_:)), with: nil)
    responder.perform(Selector(("insertText:")), with: "zero\n")
    XCTAssertEqual(document.text.lineCount, 6, "前提: 先頭に 1 行足した")

    tab.editor.activate(.diff(id("a.txt", .workingTree)))
    let rows = try engine(diff.newSurface).rows
    XCTAssertEqual(rows.boundaries, [2], "削除行は 1 行下がった TWO の前")
    XCTAssertEqual(removedLines(rows), [1])
    waitRows(diff, "足した行が追加に出る") { $0.style(ofLine: 0) == DiffStyle.added }
  }

  /// index の版が変わって底を置き直し、その行差分が届く前に外の書き換えで本文が縮んでも、並びは今の本文の外を指さない。
  /// 届けば新しい底との差分に置き直す。
  func testTheRowsStayOnTheTextWhenItShrinksBeforeTheNewBaseArrives() throws {
    try repo.write("a.txt", "one\nTWO\nthree\nfour\nfive\nsix\nseven\n")
    let (tab, _) = tab()
    let diff = try tab.editor.openDiff(id("a.txt", .workingTree), as: .pinned)
    waitRows(diff, "変更が出る") { !$0.isEmpty }
    let document = try XCTUnwrap(diff.document)
    document.baseline = "zero\n"
    try repo.write("a.txt", "one\n")
    document.reconcileWithDisk()
    XCTAssertEqual(document.text.lineCount, 2, "前提: 結果が届く前に本文が縮んだ")
    let rows = try engine(diff.newSurface).rows
    XCTAssertTrue(rows.boundaries.allSatisfy { $0 <= 1 }, "差し込みは今の本文の中")

    XCTAssertTrue(document.waitUntilCaughtUp())
    XCTAssertEqual(diff.old?.text.contiguousUnits().count, "zero\n".utf16.count, "古い側は新しい底")
    XCTAssertEqual(removedLines(try engine(diff.newSurface).rows), [0])
  }

  /// 未追跡のファイルは全部の行が追加、作業ツリーで消したファイルは全部の行が削除になる。
  func testOneSidedWorkingTreeDiffs() throws {
    try repo.write("new.txt", "x\ny\n")
    let (tab, _) = tab()
    let added = try tab.editor.openDiff(id("new.txt", .workingTree), as: .pinned)
    waitRows(added, "未追跡は全部が追加") { $0.style(ofLine: 0) == DiffStyle.added }
    XCTAssertTrue(try engine(added.newSurface).rows.isEmpty)
    try FileManager.default.removeItem(at: repo.url("a.txt"))
    let removed = try tab.editor.openDiff(id("a.txt", .workingTree), as: .pinned)
    waitRows(removed, "消したファイルは全部が削除") { self.removedLines($0) == [0, 1, 2, 3] }
    XCTAssertNil(removed.document, "新しい側の文書は無い")
  }

  /// バイナリ・シンボリックリンク・競合中は、タブは開き、本体に理由の一文が出る。
  func testUnavailableDiffsShowAReason() throws {
    try Data([0xFF, 0xFE, 0x00, 0x01]).write(to: repo.url("bin.dat"))
    XCTAssertTrue(repo.git(["add", "bin.dat"]).isSuccess)
    try FileManager.default.createSymbolicLink(
      atPath: repo.url("link.txt").path, withDestinationPath: "a.txt")
    let (tab, _) = tab()
    let pane = tab.view.editor
    let binary = try tab.editor.openDiff(id("bin.dat", .workingTree), as: .pinned)
    pumpMain(until: { binary.content == .unavailable(.notText) }, "バイナリ")
    pumpMain(until: { pane.faceContent == .notice(.editorDiffNotText) && !pane.emptyHost.isHidden })
    let link = try tab.editor.openDiff(id("link.txt", .workingTree), as: .pinned)
    pumpMain(until: { link.content == .unavailable(.symlink) }, "シンボリックリンク")
    XCTAssertTrue(pane.focusTarget === pane, "面が無ければ行き先は pane")
    XCTAssertEqual(
      pane.headerHeight, Theme.Layout.editorFileTabs + 1 + Theme.Layout.editorBreadcrumb)

    XCTAssertTrue(repo.git(["checkout", "-qb", "other"]).isSuccess)
    try repo.write("a.txt", "other\n")
    XCTAssertTrue(repo.git(["commit", "-qam", "other"]).isSuccess)
    XCTAssertTrue(repo.git(["checkout", "-q", "main"]).isSuccess)
    try repo.write("a.txt", "main\n")
    XCTAssertTrue(repo.git(["commit", "-qam", "main"]).isSuccess)
    XCTAssertFalse(repo.git(["merge", "other"]).isSuccess, "前提: 競合する")
    let conflicted = try tab.editor.openDiff(id("a.txt", .staged), as: .pinned)
    pumpMain(until: { conflicted.content == .unavailable(.conflicted) }, "競合中")
  }

  /// 見せている diff が表示できなくなれば（index の版がバイナリになった）、面は本体から外れ、理由の一文が見える。
  func testADiffThatBecomesUnavailableShowsTheReasonInsteadOfTheSurface() throws {
    try repo.write("a.txt", "one\nTWO\nthree\nfour\n")
    let (tab, _) = tab()
    let pane = tab.view.editor
    let diff = try tab.editor.openDiff(id("a.txt", .workingTree), as: .pinned)
    waitRows(diff, "変更が出る") { !$0.isEmpty }
    let surface = try engine(diff.newSurface)
    try Data([0xFF, 0xFE, 0x00, 0x01]).write(to: repo.url("a.txt"))
    XCTAssertTrue(repo.git(["add", "a.txt"]).isSuccess)
    pumpMain(until: { diff.content == .unavailable(.notText) }, "表示できなくなる")
    XCTAssertFalse(pane.emptyHost.isHidden)
    XCTAssertNil(surface.view.superview, "面は本体から外れる")
  }

  // MARK: - ステージ済み

  /// ステージ済み diff は HEAD の版 ↔ index の版で、rename なら古い側は元のパスの HEAD の版。作業ツリー diff とは別のタブ。
  func testAStagedRenameComparesTheOriginalPathsHeadVersion() throws {
    XCTAssertTrue(repo.git(["mv", "a.txt", "b.txt"]).isSuccess)
    try repo.write("b.txt", "one\ntwo\nthree\nfour\nfive\n")
    XCTAssertTrue(repo.git(["add", "b.txt"]).isSuccess)
    let (tab, _) = tab()
    let staged = try tab.editor.openDiff(id("b.txt", .staged), as: .pinned)
    waitRows(staged, "追加の 1 行") { $0.style(ofLine: 4) == DiffStyle.added }
    XCTAssertEqual(staged.old?.text.lineCount, 5, "古い側は a.txt の HEAD の版")
    XCTAssertEqual(staged.newRevision?.text.lineCount, 6)
    XCTAssertTrue(try engine(staged.newSurface).rows.boundaries.isEmpty, "削除行は無い")
    let working = try tab.editor.openDiff(id("b.txt", .workingTree), as: .pinned)
    XCTAssertFalse(working === staged)
    XCTAssertEqual(tab.editor.tabs.count, 2)
  }

  // MARK: - 並列

  /// 並列は古い側の面と新しい側の面を左右に並べてスクロールを共にし、インラインへ戻せば古い側の面は閉じる。切り替えても
  /// 見えている先頭の新しい側の行は保たれ、選んだ見せ方は全部の diff タブに効く。
  func testSideBySideSharesTheScrollAndSwitchingKeepsTheFirstVisibleLine() throws {
    let lines = (0..<200).map { "line \($0)" }
    try repo.write("long.txt", lines.joined(separator: "\n") + "\n")
    XCTAssertTrue(repo.git(["add", "-A"]).isSuccess)
    XCTAssertTrue(repo.git(["commit", "-qm", "long"]).isSuccess)
    var changed = lines
    changed[120] = "changed 120"
    changed.insert(contentsOf: ["added a", "added b"], at: 150)
    try repo.write("long.txt", changed.joined(separator: "\n") + "\n")
    let modes = EditorDiffModeState()
    let (tab, _) = tab()
    let pane = tab.view.editor
    pane.configure(
      translucency: ChromeTranslucency(), localization: LocalizationStore(language: .ja),
      fontResolver: ChromeFontResolver(), sidebar: EditorSidebarState(), diffModes: modes)
    let diff = try tab.editor.openDiff(id("long.txt", .workingTree), as: .pinned)
    waitRows(diff, "インライン") { !$0.isEmpty }
    let right = try engine(diff.newSurface)
    right.flush()
    let first = right.viewport.firstVisible
    XCTAssertGreaterThan(first, 0, "最初の変更区間へ送られている")

    modes.select(.side)
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
      XCTAssertEqual(right.viewport.firstVisible, first, "見えている先頭の行は保たれる")
      XCTAssertEqual(left.view.frame.maxX + 1, right.view.frame.minX, "境の線 1px を挟む")
    }()

    modes.select(.inline)
    pumpMain(until: { diff.oldSurface == nil && closed == nil }, "古い側の面は閉じる")
    XCTAssertNil(right.partner, "共有が外れる")
    XCTAssertEqual(right.presentation, DiffStyle.inline)
    right.flush()
    XCTAssertEqual(right.viewport.firstVisible, first)
  }

  private func diffSurfaceCount(_ pane: EditorPaneView) -> Int {
    pane.diff.map { pane.diffSurfaces($0).count } ?? 0
  }

  // MARK: - 文書の持ち主

  /// 未保存の文書のファイルタブを閉じても、同じ文書を diff タブが使っていれば確認は出ず、diff タブに未保存の印が出る。
  /// その diff タブを閉じるときに確認が出る。
  func testTheUnsavedPromptComesOnlyWhenTheLastTabOfADocumentCloses() throws {
    let (tab, window) = tab()
    let pane = tab.view.editor
    let document = try tab.editor.open(repo.url("a.txt"), as: .pinned)
    document.surface.responder.perform(Selector(("insertText:")), with: "Z")
    XCTAssertTrue(document.isDirty)
    try tab.editor.openDiff(id("a.txt", .workingTree), as: .pinned)
    pane.shell.requestClose(.document(document.url))
    XCTAssertNil(window.attachedSheet, "diff タブが使っていれば確認しない")
    XCTAssertEqual(tab.editor.tabs.count, 1)
    XCTAssertEqual(tab.editor.documents.count, 1, "文書は diff タブが持つ")
    XCTAssertEqual(pane.shell.tabs.map(\.isDirty), [true], "diff タブに未保存の印")
    XCTAssertEqual(tab.unsavedDocuments().count, 1, "閉じれば失われる文書に数える")

    pane.shell.requestClose(.diff(id("a.txt", .workingTree)))
    let sheet = try XCTUnwrap(window.attachedSheet, "最後のタブで確認")
    window.endSheet(sheet, returnCode: .alertSecondButtonReturn)
    XCTAssertTrue(tab.editor.tabs.isEmpty)
    XCTAssertTrue(tab.editor.documents.isEmpty)
  }

  /// 仮のタブの枠は文書と diff で 1 つ——仮で開いた diff は、次に仮で開いた文書に同じ位置で入れ替わる。
  func testTheTemporaryTabSlotIsSharedByDocumentsAndDiffs() throws {
    try repo.write("b.txt", "b\n")
    let (tab, _) = tab()
    try tab.editor.open(repo.url("b.txt"), as: .pinned)
    try tab.editor.openDiff(id("a.txt", .workingTree), as: .preview)
    XCTAssertEqual(tab.editor.previewID, .diff(id("a.txt", .workingTree)))
    XCTAssertEqual(tab.view.editor.shell.tabs.map(\.isPreview), [false, true])
    try tab.editor.open(repo.url("a.txt"), as: .preview)
    XCTAssertEqual(
      tab.editor.tabs.map(\.id), [.document(repo.url("b.txt")), .document(repo.url("a.txt"))])
    XCTAssertEqual(tab.editor.previewID, .document(repo.url("a.txt")))
  }

  // MARK: - 永続と現在地

  /// diff タブは永続に書かない。焦点が diff タブなら、diff タブを除いた列でその位置にある文書のタブ（右隣、無ければ左隣。閉じたときと同じ）を
  /// 焦点として書く。現在地は diff タブでもファイルと同じ（根と相対パス）。
  func testDiffTabsAreNotPersistedAndTheLocationIsTheFile() throws {
    try repo.write("b.txt", "b\n")
    let (tab, _) = tab()
    try tab.editor.open(repo.url("b.txt"), as: .pinned)
    try tab.editor.openDiff(id("a.txt", .workingTree), as: .pinned)
    try tab.editor.open(repo.url("a.txt"), as: .pinned)
    tab.editor.activate(.diff(id("a.txt", .workingTree)))
    let documents = try XCTUnwrap(tab.tabState().editor?.documents)
    XCTAssertEqual(documents.open, [repo.url("b.txt").path, repo.url("a.txt").path])
    XCTAssertEqual(documents.active, repo.url("a.txt").path, "閉じたときと同じく右隣の文書のタブ")
    XCTAssertEqual(tab.location, .file(root: repo.root, relative: "a.txt"))
  }
}
