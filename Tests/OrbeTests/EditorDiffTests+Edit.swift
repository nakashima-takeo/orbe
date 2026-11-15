import AppKit
import OrbeEditorCore
import XCTest

@testable import Orbe
@testable import OrbeEditorEngine

/// diff の中の編集——作業ツリー diff の新しい側（インラインの本文・並列の右）はファイルタブと同じ文書と undo で編集でき、
/// diff の行の並び（追加の行・削除行・並列の詰め物）は編集に追従し、⌘S で保存でき、外部変更は、未保存かどうかで差し替えか
/// 衝突の印になる。ステージ済み diff・並列の左・消したファイルの新しい側は読むだけ。壊れると、diff で打った字が本文に
/// 入らない・並びが本文からずれる・並列の左右の高さがずれる・diff で直した変更を保存できない・仮の diff タブが未保存のまま
/// 入れ替わる・index の版を書き換えてしまう・プロジェクト検索の一致が diff で打った字からずれる。
extension EditorDiffTests {
  private func type(_ text: String, at location: Int, on surface: MetalTextSurface) {
    surface.selectedRange = NSRange(location: location, length: 0)
    surface.responder.perform(#selector(NSResponder.insertText(_:)), with: text)
  }

  private func string(_ text: TextRope?) -> String? {
    text.map { String(decoding: $0.contiguousUnits(), as: UTF16.self) }
  }

  /// 打った編集は文書の本文に入り、未保存になる。変更の区間に足した行はその場で追加の行になり、変えていない行を変えると
  /// 裏の行差分が届いた時点で追加の行になって元の行が削除行に出る。undo で戻せば変更の表示も戻る。
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

    let undo = try XCTUnwrap(surface.responder.undoManager)
    while undo.canUndo { undo.undo() }
    XCTAssertEqual(string(document.text), "one\nTWO\nthree\nfour\n")
    waitRows(diff, "undo で変更の表示も戻る") {
      self.removedLines($0) == [1] && $0.style(ofLine: 3) == nil
    }
  }

  /// 並列の右で行を足し引きしても、左右の同じ行は同じ高さに揃い続ける（裏の結果を待つ前も後も）。左で打っても古い側も
  /// 文書も変わらない。
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

    window.makeFirstResponder(left.responder)
    type("Q", at: 0, on: left)
    XCTAssertEqual(string(diff.old?.text), "one\ntwo\nthree\nfour\n", "左は読むだけ")
    XCTAssertEqual(string(document.text), "one\nTWO\nthree\nfour\n")
  }

  /// 変換中に見せ方（インライン ⇄ 並列）を切り替えても、同じ面のまま変換が続き、確定した字が本文に入る。
  func testSwitchingTheModeWhileComposingKeepsTheComposition() throws {
    try repo.write("a.txt", "one\nTWO\nthree\nfour\n")
    let modes = EditorDiffModeState()
    let (tab, window) = tab(modes: modes)
    let diff = try tab.group.editor.openDiff(id("a.txt", .workingTree), as: .pinned)
    waitRows(diff, "変更が出る") { !$0.isEmpty }
    let document = try XCTUnwrap(diff.document)
    let surface = try engine(diff.newSurface)
    window.makeFirstResponder(surface.responder)
    surface.selectedRange = NSRange(location: 13, length: 0)
    let client = try XCTUnwrap(surface.responder as? NSTextInputClient)
    let whole = NSRange(location: NSNotFound, length: 0)
    client.setMarkedText(
      "か", selectedRange: NSRange(location: 1, length: 0), replacementRange: whole)

    modes.select(.side)
    pumpMain(until: { diff.oldSurface != nil }, "並列")
    XCTAssertTrue(diff.newSurface === surface, "前提: 同じ面")
    XCTAssertTrue(client.hasMarkedText(), "変換は続く")
    client.setMarkedText(
      "かな", selectedRange: NSRange(location: 2, length: 0), replacementRange: whole)
    client.insertText("仮名", replacementRange: whole)
    XCTAssertFalse(client.hasMarkedText())
    XCTAssertEqual(string(document.text), "one\nTWO\nthree仮名\nfour\n")
  }

  /// 仮の diff タブで打つと普通のタブになり、未保存の印が出る。同じファイルのファイルタブは同じ本文と undo を持ち、ファイル
  /// タブでの ⌘Z が diff の中の編集を戻す。
  func testEditingAPreviewDiffPinsItAndTheFileTabSharesTheUndo() throws {
    try repo.write("a.txt", "one\nTWO\nthree\nfour\n")
    let (tab, window) = tab()
    let pane = tab.group.view.editor
    let key = id("a.txt", .workingTree)
    let diff = try tab.group.editor.openDiff(key, as: .preview)
    waitRows(diff, "変更が出る") { !$0.isEmpty }
    XCTAssertEqual(tab.group.editor.previewID, .diff(key), "前提: 仮のタブ")
    let surface = try engine(diff.newSurface)
    window.makeFirstResponder(surface.responder)

    type("Z", at: 0, on: surface)
    XCTAssertNil(tab.group.editor.previewID, "打てば普通のタブ")
    XCTAssertEqual(pane.shell.tabs.map(\.isDirty), [true], "diff タブに未保存の印")

    let document = try tab.group.editor.open(repo.url("a.txt"), as: .preview)
    XCTAssertTrue(document === diff.document, "同じ文書")
    XCTAssertEqual(string(document.text), "Zone\nTWO\nthree\nfour\n")
    XCTAssertEqual(pane.shell.tabs.map(\.isDirty), [true, true])
    try XCTUnwrap(document.surface.responder.undoManager).undo()
    XCTAssertEqual(string(document.text), "one\nTWO\nthree\nfour\n", "ファイルタブの ⌘Z が diff の編集を戻す")
    pumpMain(until: { !document.isDirty }, "未保存でなくなる")
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

  /// diff を出している間に、未保存でない文書が外で書き換わると本文が差し替わり、⌘Z で差し替え前の本文へ、さらにその前の
  /// 編集の前へ戻れる。未保存の間に外で書き換われば、本文は保たれて衝突の印が立つ。
  func testAnExternalWriteWhileTheDiffIsShownIsUndoable() throws {
    try repo.write("a.txt", "one\nTWO\nthree\nfour\n")
    let (tab, window) = tab()
    let diff = try tab.group.editor.openDiff(id("a.txt", .workingTree), as: .pinned)
    waitRows(diff, "変更が出る") { !$0.isEmpty }
    let document = try XCTUnwrap(diff.document)
    let surface = try engine(diff.newSurface)
    window.makeFirstResponder(surface.responder)
    type("Z", at: 0, on: surface)
    try document.save()

    try repo.write("a.txt", "outside\n")
    document.reconcileWithDisk()
    XCTAssertEqual(string(document.text), "outside\n", "未保存でなければ差し替わる")
    XCTAssertFalse(document.isDirty)
    let undo = try XCTUnwrap(surface.responder.undoManager)
    undo.undo()
    XCTAssertEqual(string(document.text), "Zone\nTWO\nthree\nfour\n", "差し替え前の本文へ戻る")
    undo.undo()
    XCTAssertEqual(string(document.text), "one\nTWO\nthree\nfour\n", "差し替え前の取り消しの履歴も残る")

    XCTAssertTrue(document.isDirty, "前提: 未保存")
    try repo.write("a.txt", "again\n")
    document.reconcileWithDisk()
    XCTAssertEqual(string(document.text), "one\nTWO\nthree\nfour\n", "未保存の本文は保たれる")
    XCTAssertTrue(document.isDiskChanged, "衝突の印")
  }

  /// ステージ済み diff の新しい側、並列の左、消したファイルの新しい側は、打っても ⌘Z を押しても本文が変わらない。
  func testStagedDiffsTheLeftSideAndRemovedFilesAreNotEdited() throws {
    try repo.write("gone.txt", "gone\n")
    XCTAssertTrue(repo.git(["add", "-A"]).isSuccess)
    XCTAssertTrue(repo.git(["commit", "-qm", "gone"]).isSuccess)
    try FileManager.default.removeItem(at: repo.url("gone.txt"))
    try repo.write("a.txt", "one\nTWO\nthree\nfour\n")
    XCTAssertTrue(repo.git(["add", "a.txt"]).isSuccess)
    try repo.write("a.txt", "one\nTWO\nthree\nFOUR\n")
    let modes = EditorDiffModeState()
    let (tab, window) = tab(modes: modes)
    let typeAndUndo = { (name: String, surface: MetalTextSurface, text: () -> String?) in
      let before = text()
      window.makeFirstResponder(surface.responder)
      self.type("Q", at: 0, on: surface)
      surface.responder.perform(NSSelectorFromString("undo:"), with: nil)
      XCTAssertEqual(text(), before, "\(name) は読むだけ")
    }

    let staged = try tab.group.editor.openDiff(id("a.txt", .staged), as: .pinned)
    waitRows(staged, "ステージ済み") { !$0.isEmpty }
    typeAndUndo("ステージ済みの新しい側", try engine(staged.newSurface)) {
      self.string(staged.newRevision?.text)
    }
    let removed = try tab.group.editor.openDiff(id("gone.txt", .workingTree), as: .pinned)
    waitRows(removed, "消したファイル") { !self.removedLines($0).isEmpty }
    typeAndUndo("消したファイルの新しい側", try engine(removed.newSurface)) {
      self.string(removed.newRevision?.text)
    }
    modes.select(.side)
    let working = try tab.group.editor.openDiff(id("a.txt", .workingTree), as: .pinned)
    pumpMain(until: { working.content == .ready && working.oldSurface != nil }, "並列")
    typeAndUndo("並列の左", try engine(working.oldSurface)) { self.string(working.old?.text) }
  }

  /// diff の中の編集は、プロジェクト検索の結果に出ているそのファイルの一致をずらし、少し後にその文書だけを探し直す。
  func testEditsInTheDiffShiftTheProjectSearchMatches() throws {
    try repo.write("a.txt", "one\nneedle\nthree\nfour\n")
    let (tab, window) = tab()
    let pane = tab.group.view.editor
    let diff = try tab.group.editor.openDiff(id("a.txt", .workingTree), as: .pinned)
    waitRows(diff, "変更が出る") { !$0.isEmpty }
    let document = try XCTUnwrap(diff.document)
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
    XCTAssertEqual(search.results["a.txt"]?.matches.first?.preview.before, "", "探し直すまで前の行")
    pumpMain(
      until: { search.results["a.txt"]?.matches.first?.preview.before == "abc" }, "少し後に探し直す")
    XCTAssertEqual(search.results["a.txt"]?.document?.version, document.version)
  }
}
