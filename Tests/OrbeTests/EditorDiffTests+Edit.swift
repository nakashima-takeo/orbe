import AppKit
import OrbeEditorCore
import XCTest

@testable import Orbe
@testable import OrbeEditorEngine

/// diff の中の編集——作業ツリー diff の新しい側（インラインの本文・並列の右）で打った字は文書に入り、diff の行の並び（追加の
/// 行・削除行・並列の詰め物）は編集に追従し、⌘S で保存できる。壊れると、diff で打った字が本文に入らない・並びが本文から
/// ずれる・並列の左右の高さがずれる・変換中の字が消える・仮の diff タブが未保存のまま入れ替わる・diff で直した変更を保存
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
    let diff = try tab.group.editor.openDiff(id("a.txt", .workingTree), as: .pinned)
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
    let (tab, window) = tab(modes: EditorDiffModeState(mode: .side))
    let diff = try tab.group.editor.openDiff(id("a.txt", .workingTree), as: .pinned)
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
    let (tab, window) = tab(modes: EditorDiffModeState(mode: .side))
    let diff = try tab.group.editor.openDiff(id("new.txt", .workingTree), as: .pinned)
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
    let modes = EditorDiffModeState()
    let (tab, window) = tab(modes: modes)
    let diff = try tab.group.editor.openDiff(id("a.txt", .workingTree), as: .pinned)
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
    modes.select(.side)
    pumpMain(until: { diff.oldSurface != nil }, "並列")
    XCTAssertTrue(diff.newSurface === surface, "前提: 同じ面")
    XCTAssertTrue(client.hasMarkedText(), "見せ方を切り替えても変換は続く")
    client.setMarkedText(
      "かな", selectedRange: NSRange(location: 2, length: 0), replacementRange: whole)
    client.insertText("仮名", replacementRange: whole)
    XCTAssertFalse(client.hasMarkedText())
    XCTAssertEqual(string(document.text), "one\nTWO\nthree仮名\nfour\n")
  }

  /// 仮の diff タブで打つと普通のタブになり（次に仮で開いたものとの入れ替えで未保存の本文が消えない）、未保存の印が出る。
  func testEditingAPreviewDiffPinsIt() throws {
    try repo.write("a.txt", "one\nTWO\nthree\nfour\n")
    let (tab, window) = tab()
    let key = id("a.txt", .workingTree)
    let diff = try tab.group.editor.openDiff(key, as: .preview)
    waitRows(diff, "変更が出る") { !$0.isEmpty }
    XCTAssertEqual(tab.group.editor.previewID, .diff(key), "前提: 仮のタブ")
    let surface = try engine(diff.newSurface)
    window.makeFirstResponder(surface.responder)

    type("Z", at: 0, on: surface)
    XCTAssertNil(tab.group.editor.previewID, "打てば普通のタブ")
    XCTAssertEqual(tab.group.view.editor.shell.tabs.map(\.isDirty), [true], "diff タブに未保存の印")
  }

  /// diff のタブで ⌘S を押すと文書を保存し、未保存の印が消える。ディスクが外で変わっていて未保存の編集があれば上書きの確認が
  /// 出て、上書きを選べば保存する。
  func testSavingFromTheDiffTabWritesTheDocument() throws {
    try repo.write("a.txt", "one\nTWO\nthree\nfour\n")
    let (tab, window) = tab()
    let pane = tab.group.view.editor
    let diff = try tab.group.editor.openDiff(id("a.txt", .workingTree), as: .pinned)
    waitRows(diff, "変更が出る") { !$0.isEmpty }
    let document = try XCTUnwrap(diff.document)
    let surface = try engine(diff.newSurface)
    window.makeFirstResponder(surface.responder)

    type("Z", at: 0, on: surface)
    XCTAssertTrue(pane.performKeyEquivalent(with: .key("s")))
    XCTAssertFalse(document.isDirty)
    XCTAssertEqual(pane.shell.tabs.map(\.isDirty), [false], "未保存の印が消える")
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

  /// diff の中の編集は、プロジェクト検索の結果に出ているそのファイルの一致を編集に合わせてずらす（ファイルタブで編集した
  /// ときと同じ配り先に届く）。
  func testEditsInTheDiffShiftTheProjectSearchMatches() throws {
    try repo.write("a.txt", "one\nneedle\nthree\nfour\n")
    let (tab, window) = tab()
    let pane = tab.group.view.editor
    let diff = try tab.group.editor.openDiff(id("a.txt", .workingTree), as: .pinned)
    waitRows(diff, "変更が出る") { !$0.isEmpty }
    let search = pane.projectSearch
    pane.showProjectSearch(seed: nil)
    search.setPattern("needle")
    search.search()
    pumpMain(until: { search.phase == .done }, "検索が終わる")
    XCTAssertEqual(
      search.results["a.txt"]?.document?.ranges, [NSRange(location: 4, length: 6)],
      "前提: 開いている文書の結果")

    let surface = try engine(diff.newSurface)
    window.makeFirstResponder(surface.responder)
    type("abc", at: 4, on: surface)
    XCTAssertEqual(
      search.results["a.txt"]?.document?.ranges, [NSRange(location: 7, length: 6)], "一致は編集でずれる")
  }

}
