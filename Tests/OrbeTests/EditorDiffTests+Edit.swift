import AppKit
import OrbeEditorCore
import OrbeTestSupport
import XCTest

@testable import Orbe
@testable import OrbeEditorEngine

/// diff の中の編集——作業ツリー diff の新しい側（インラインの本文・並列の右）で打った字は文書に入り、diff の行の並び（追加の
/// 行・削除行・並列の詰め物）は編集に追従し、⌘S で保存できる。壊れると、diff で打った字が本文に入らない・並びが本文から
/// ずれる・並列の左右の高さがずれる・変換中の字が消える・diff で打った未保存の文書が開いている文書の列に入らない・diff で直した変更を保存
/// できない・プロジェクト検索の一致が diff で打った字からずれる。
extension EditorDiffTests {
  private func type(_ text: String, at location: Int, on surface: MetalTextSurface) {
    surface.selectedRange = NSRange(location: location, length: 0)
    surface.responder.perform(#selector(NSResponder.insertText(_:)), with: text)
  }

  private func string(_ text: TextRope?) -> String? {
    text.map { String(decoding: $0.contiguousUnits(), as: UTF16.self) }
  }

  /// 打った編集は文書の本文に入り、未保存になる。変更の区間に足した行はその場で追加の行になり、変えていない行を変えると
  /// 裏の行差分が届いた時点で追加の行になって元の行が削除行に出る。
  func testTypingInAnInlineDiffEditsTheDocumentAndTheRowsFollow() throws {
    try repo.write("a.txt", "one\nTWO\nthree\nfour\n")
    let (tab, window) = tab()
    let diff = try tab.group.editor.openDiff(id("a.txt", .workingTree))
    waitRows(diff, "変更が出る") { $0.boundaries == [1] }
    let document = try XCTUnwrap(diff.document)
    XCTAssertTrue(document.waitUntilCaughtUp())
    let surface = try engine(diff.newSurface)
    window.makeFirstResponder(surface.responder)

    type("\nADDED", at: 7, on: surface)
    XCTAssertEqual(string(document.text), "one\nTWO\nADDED\nthree\nfour\n")
    XCTAssertTrue(document.isDirty)
    XCTAssertEqual(surface.rows.style(ofLine: 2), DiffStyle.added, "変更の区間に足した行はその場で追加")
    XCTAssertEqual(removedLines(surface.rows), [1])

    type("!", at: 24, on: surface)
    waitRows(diff, "変えていない行は、裏の結果で追加になり元の行が削除行に出る") {
      $0.style(ofLine: 4) == DiffStyle.added && self.removedLines($0) == [1, 3]
    }
  }

  /// 並列の右で行を足し引きしても、左右の同じ行は同じ高さに揃い続ける（裏の結果を待つ前も後も）。
  func testTheRightSideOfASideBySideDiffIsEditedAndStaysAligned() throws {
    try repo.write("a.txt", "one\nTWO\nthree\nfour\n")
    let (tab, window) = tab(width: Self.sideWidth)
    let diff = try tab.group.editor.openDiff(id("a.txt", .workingTree))
    pumpMain(until: { diff.content == .ready && diff.oldSurface != nil }, "並列")
    let document = try XCTUnwrap(diff.document)
    XCTAssertTrue(document.waitUntilCaughtUp())
    let (left, right) = (try engine(diff.oldSurface), try engine(diff.newSurface))
    let oldLines = try XCTUnwrap(diff.old).text.lineCount
    let aligned = {
      left.rows.lastUnit(lineCount: oldLines)
        == right.rows.lastUnit(lineCount: document.text.lineCount)
    }
    window.makeFirstResponder(right.responder)

    type("\nnew", at: 13, on: right)
    XCTAssertEqual(string(document.text), "one\nTWO\nthree\nnew\nfour\n")
    XCTAssertTrue(aligned(), "足した直後も揃う")
    XCTAssertTrue(document.waitUntilCaughtUp())
    XCTAssertEqual(right.rows.style(ofLine: 3), DiffStyle.added, "足した行は追加")
    XCTAssertTrue(aligned(), "裏の結果の後も揃う")
    right.selectedRange = NSRange(location: 13, length: 4)
    right.responder.deleteBackward(nil)
    XCTAssertEqual(string(document.text), "one\nTWO\nthree\nfour\n", "前提: 足した行を消した")
    XCTAssertTrue(aligned(), "消した直後も揃う")
    XCTAssertTrue(document.waitUntilCaughtUp())
    XCTAssertTrue(aligned())
  }

  /// 未追跡のファイルの並列の diff で右に行を足し続けても、左右の高さの揃い方は開いたときのまま（古い側が文書の底では
  /// ない diff は、本文が変わるたびに今の行の数で並びを置き直す）。
  func testAddingLinesToAnUntrackedFileKeepsTheSideBySideAligned() throws {
    try repo.write("new.txt", "x\ny\n")
    let (tab, window) = tab(width: Self.sideWidth)
    let diff = try tab.group.editor.openDiff(id("new.txt", .workingTree))
    pumpMain(until: { diff.content == .ready && diff.oldSurface != nil }, "並列")
    let document = try XCTUnwrap(diff.document)
    let (left, right) = (try engine(diff.oldSurface), try engine(diff.newSurface))
    let oldLines = try XCTUnwrap(diff.old).text.lineCount
    let gap = {
      left.rows.lastUnit(lineCount: oldLines)
        - right.rows.lastUnit(lineCount: document.text.lineCount)
    }
    let opened = gap()
    window.makeFirstResponder(right.responder)

    for added in 1...3 {
      type("\n", at: 0, on: right)
      XCTAssertEqual(gap(), opened, "\(added) 行足した後も、揃い方は開いたときのまま")
    }
  }

  /// 変えていない行で変換を始めると、裏の行差分が届いて元の行が削除行として差し込まれ、さらに見せ方（インライン ⇄ 並列）を
  /// 切り替えても、変換は続き、確定した字が本文に入る。
  func testTheCompositionContinuesWhileTheRowsChangeUnderIt() throws {
    try repo.write("a.txt", "one\nTWO\nthree\nfour\n")
    let (tab, window) = tab()
    let diff = try tab.group.editor.openDiff(id("a.txt", .workingTree))
    waitRows(diff, "変更が出る") { self.removedLines($0) == [1] }
    let document = try XCTUnwrap(diff.document)
    let surface = try engine(diff.newSurface)
    window.makeFirstResponder(surface.responder)
    surface.selectedRange = NSRange(location: 13, length: 0)
    let client = try XCTUnwrap(surface.responder as? NSTextInputClient)
    let whole = NSRange(location: NSNotFound, length: 0)
    client.setMarkedText(
      "か", selectedRange: NSRange(location: 1, length: 0), replacementRange: whole)

    waitRows(diff, "変換中の行の元の行が削除行に出る") { self.removedLines($0) == [1, 2] }
    XCTAssertTrue(client.hasMarkedText(), "削除行が差し込まれても変換は続く")
    resize(window, width: Self.sideWidth)
    pumpMain(until: { diff.oldSurface != nil }, "並列")
    XCTAssertTrue(diff.newSurface === surface, "前提: 同じ面")
    XCTAssertTrue(client.hasMarkedText(), "見せ方を切り替えても変換は続く")
    client.setMarkedText(
      "かな", selectedRange: NSRange(location: 2, length: 0), replacementRange: whole)
    client.insertText("仮名", replacementRange: whole)
    XCTAssertFalse(client.hasMarkedText())
    XCTAssertEqual(string(document.text), "one\nTWO\nthree仮名\nfour\n")
  }

  /// diff の中で打って未保存にすると、その文書が開いている文書の列へ普通の文書として入る（次の diff へ入れ替えても
  /// 未保存の本文が消えない）。列が空なら今の文書になる。画面は変わらない。
  func testEditingInADiffPutsTheDocumentIntoTheOpenDocuments() throws {
    try repo.write("a.txt", "one\nTWO\nthree\nfour\n")
    try repo.write("b.txt", "b\n")
    let (tab, window) = tab()
    let diff = try tab.group.editor.openDiff(id("a.txt", .workingTree))
    waitRows(diff, "変更が出る") { !$0.isEmpty }
    let document = try XCTUnwrap(diff.document)
    XCTAssertTrue(tab.group.editor.documents.isEmpty, "前提: 列は空")
    let surface = try engine(diff.newSurface)
    window.makeFirstResponder(surface.responder)

    type("Z", at: 0, on: surface)
    XCTAssertEqual(tab.group.editor.documents.map(\.url), [document.url], "未保存になった文書が列に入る")
    XCTAssertNil(tab.group.editor.previewURL, "普通の文書")
    XCTAssertEqual(tab.group.editor.screen, .changes, "画面は変わらない")
    XCTAssertEqual(tab.group.editor.documents.map(\.isDirty), [true], "列の文書が未保存")

    try tab.group.editor.openDiff(id("b.txt", .workingTree))
    XCTAssertEqual(tab.group.editor.documents.map(\.url), [document.url], "別の diff へ入れ替えても文書は残る")
    XCTAssertTrue(document.isDirty)
  }

  /// diff の中で未保存になった文書は、列の 2 番目（今の文書のすぐ次）に入る——今の文書は替わらず、直前に触った文書として
  /// 開いているファイルの一覧の 2 行目に出る。
  func testADocumentEditedInADiffEntersSecond() throws {
    try repo.write("a.txt", "one\nTWO\nthree\nfour\n")
    try repo.write("c.txt", "c\n")
    try repo.write("d.txt", "d\n")
    let (tab, window) = tab()
    let c = try tab.group.editor.open(repo.url("c.txt"), as: .pinned)
    let d = try tab.group.editor.open(repo.url("d.txt"), as: .pinned)
    let diff = try tab.group.editor.openDiff(id("a.txt", .workingTree))
    waitRows(diff, "変更が出る") { !$0.isEmpty }
    let document = try XCTUnwrap(diff.document)
    let surface = try engine(diff.newSurface)
    window.makeFirstResponder(surface.responder)

    type("Z", at: 0, on: surface)
    XCTAssertTrue(
      tab.group.editor.documents.elementsEqual([d, document, c], by: ===), "2 番目に入る")
    XCTAssertTrue(tab.group.editor.activeDocument === d, "今の文書は替わらない")
  }

  /// diff の中で ⌘S を押すと文書を保存し、未保存の印が消える。ディスクが外で変わっていて未保存の編集があれば上書きの確認が
  /// 出て、上書きを選べば保存する。
  func testSavingFromTheDiffWritesTheDocument() throws {
    try repo.write("a.txt", "one\nTWO\nthree\nfour\n")
    let (tab, window) = tab()
    let pane = tab.group.view.editor
    let diff = try tab.group.editor.openDiff(id("a.txt", .workingTree))
    waitRows(diff, "変更が出る") { !$0.isEmpty }
    let document = try XCTUnwrap(diff.document)
    let surface = try engine(diff.newSurface)
    window.makeFirstResponder(surface.responder)

    type("Z", at: 0, on: surface)
    XCTAssertTrue(pane.performKeyEquivalent(with: .key("s")))
    XCTAssertFalse(document.isDirty)
    XCTAssertEqual(tab.group.editor.documents.map(\.isDirty), [false], "未保存が消える")
    XCTAssertEqual(
      try String(contentsOf: repo.url("a.txt"), encoding: .utf8), "Zone\nTWO\nthree\nfour\n")

    type("Y", at: 0, on: surface)
    try repo.write("a.txt", "outside\n")
    XCTAssertTrue(pane.performKeyEquivalent(with: .key("s")))
    let sheet = try XCTUnwrap(window.attachedSheet, "上書きの確認")
    window.endSheet(sheet, returnCode: .alertFirstButtonReturn)
    XCTAssertEqual(
      try String(contentsOf: repo.url("a.txt"), encoding: .utf8), "YZone\nTWO\nthree\nfour\n",
      "上書きで保存する")
    XCTAssertFalse(document.isDirty)
  }

  /// diff の中の編集は、プロジェクト検索の結果に出ているそのファイルの一致を編集に合わせてずらす（Files の画面で文書を編集
  /// したときと同じ配り先に届く）。検索は Files の画面で行い、Changes の画面へ戻って diff の中で打つ。
  func testEditsInTheDiffShiftTheProjectSearchMatches() throws {
    try repo.write("a.txt", "one\nneedle\nthree\nfour\n")
    let (tab, window) = tab()
    let pane = tab.group.view.editor
    let diff = try tab.group.editor.openDiff(id("a.txt", .workingTree))
    waitRows(diff, "変更が出る") { !$0.isEmpty }
    let search = pane.projectSearch
    pane.showProjectSearch(seed: nil)
    search.setPattern("needle")
    search.search()
    pumpMain(until: { search.phase == .done }, "検索が終わる")
    XCTAssertEqual(
      search.results["a.txt"]?.document?.ranges, [NSRange(location: 4, length: 6)],
      "前提: 開いている文書の結果")
    tab.group.editor.selectScreen(.changes)

    let surface = try engine(diff.newSurface)
    window.makeFirstResponder(surface.responder)
    type("abc", at: 4, on: surface)
    XCTAssertEqual(
      search.results["a.txt"]?.document?.ranges, [NSRange(location: 7, length: 6)], "一致は編集でずれる")
  }

  /// ファイルが消えて戻り、diff の新しい側が戻ったファイルの文書に替わった後も、diff の中の編集はプロジェクト検索の一致を
  /// ずらす（替わった文書の知らせに結び直す）。
  func testEditsAfterTheFileComesBackStillShiftTheProjectSearchMatches() throws {
    try repo.write("a.txt", "one\nneedle\nthree\nfour\n")
    let (tab, window) = tab()
    let pane = tab.group.view.editor
    let diff = try tab.group.editor.openDiff(id("a.txt", .workingTree))
    waitRows(diff, "変更が出る") { !$0.isEmpty }
    let contents = try Data(contentsOf: repo.url("a.txt"))
    try FileManager.default.removeItem(at: repo.url("a.txt"))
    pumpMain(until: { diff.document == nil && diff.content == .ready }, "消えたファイルの diff")
    try contents.write(to: repo.url("a.txt"))
    try XCTUnwrap(diff.rootObserver).rootFiles(diff.files, filesDidChange: .scanAll)
    waitRows(diff, "戻ったファイルの文書で並びが出る") { !$0.isEmpty }
    let search = pane.projectSearch
    pane.showProjectSearch(seed: nil)
    search.setPattern("needle")
    search.search()
    pumpMain(until: { search.phase == .done }, "検索が終わる")
    tab.group.editor.selectScreen(.changes)

    let surface = try engine(diff.newSurface)
    window.makeFirstResponder(surface.responder)
    type("abc", at: 4, on: surface)
    XCTAssertEqual(
      search.results["a.txt"]?.document?.ranges, [NSRange(location: 7, length: 6)], "一致は編集でずれる")
  }
}
