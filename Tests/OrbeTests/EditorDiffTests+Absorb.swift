import AppKit
import OrbeEditorCore
import XCTest

@testable import Orbe
@testable import OrbeEditorEngine

/// cd で連が畳まれるとき（`TabGroup.absorb`）の diff タブ——行き先の列へ移り、元の連が消えた後も行き先で見せて追従し、同じ
/// ファイルの文書はファイルタブと diff の両側で 1 つに揃う。壊れると、cd で diff タブが消える・元の連の解放後に作業ツリーが
/// 変わると落ちる・ファイルタブと diff が別の文書を編集して未保存の印と確認が割れる・diff だけが使っていた未保存の編集が
/// 確認なしに消える。
extension EditorDiffTests {
  /// 窓に載せない連（畳まれる元の連）。
  private func bareGroup() -> TabGroup {
    TabGroup(key: repo.root, editorSurfaces: EditorSurfaces(queriesRoot: nil))
  }

  func testAMovedDiffTabKeepsShowingAndFollowingAfterItsGroupIsGone() throws {
    try repo.write("a.txt", "one\nTWO\nthree\nfour\n")
    try repo.write("b.txt", "b\n")
    let (dest, _) = tab()
    try dest.group.editor.open(repo.url("b.txt"), as: .pinned)
    weak var gone: TabGroup?
    let diff = try { () throws -> EditorDiff in
      let from = bareGroup()
      gone = from
      let diff = try from.editor.openDiff(id("a.txt", .workingTree), as: .pinned)
      waitRows(diff, "元の連で見せている") { !$0.isEmpty }
      dest.group.absorb(from)
      return diff
    }()
    XCTAssertNil(gone, "前提: 元の連は解放された")
    XCTAssertEqual(
      dest.group.editor.tabs.map(\.id),
      [.document(repo.url("b.txt")), .diff(id("a.txt", .workingTree))], "列の末尾へ移る")

    dest.group.editor.activate(.diff(id("a.txt", .workingTree)))
    let pane = dest.group.view.editor
    XCTAssertTrue(pane.diff === diff)
    XCTAssertTrue(try engine(diff.newSurface).view.isDescendant(of: pane), "行き先の面に出る")
    try repo.write("a.txt", "one\nTWO\nthree\n")
    waitRows(diff, "外の書き換えに追従する") { self.removedLines($0) == [1, 3] }
  }

  /// 元の連で見せていた diff は畳みで見せるのをやめる——同じファイルを行き先のファイルタブで見せていれば、そのタブは編集
  /// できるコードの見え方のまま（diff の見え方が載らない）。
  func testAbsorbDoesNotCarryTheShownDiffsLookOntoTheDestinationsFileTab() throws {
    try repo.write("a.txt", "one\nTWO\nthree\nfour\n")
    let (dest, _) = tab()
    let document = try dest.group.editor.open(repo.url("a.txt"), as: .pinned)
    let from = bareGroup()
    let diff = try from.editor.openDiff(id("a.txt", .workingTree), as: .pinned)
    waitRows(diff, "元の連で見せている") { !$0.isEmpty }

    dest.group.absorb(from)

    let surface = try engine(document.surface)
    XCTAssertTrue(surface.isEditable)
    XCTAssertEqual(surface.presentation, .code)
    XCTAssertTrue(surface.rows.isEmpty)
  }

  /// 勝つのは片側だけが未保存ならその側の文書（→ `EditorSession.adopt`）。行き先にあった diff も、移ってきた diff も勝った
  /// 文書を使う。
  func testAbsorbLeavesOneDocumentPerFileAcrossFileTabsAndDiffs() throws {
    try repo.write("b.txt", "b\n")
    let (dest, _) = tab()
    let from = bareGroup()
    let b = try dest.group.editor.open(repo.url("b.txt"), as: .pinned)
    b.surface.responder.perform(Selector(("insertText:")), with: "m")
    let destDiff = try dest.group.editor.openDiff(id("a.txt", .workingTree), as: .pinned)
    waitRows(destDiff, "行き先で見せている") { _ in true }
    let a = try from.editor.open(repo.url("a.txt"), as: .pinned)
    a.surface.responder.perform(Selector(("insertText:")), with: "t")
    let movedDiff = try from.editor.openDiff(id("b.txt", .workingTree), as: .pinned)

    dest.group.absorb(from)

    XCTAssertTrue(destDiff.document === a, "行き先の diff は元の未保存の文書を使う")
    XCTAssertTrue(movedDiff.document === b, "移った diff は行き先の未保存の文書を使う")
    pumpMain(
      until: { a.surface.view.isDescendant(of: dest.group.view.editor) },
      "見せている diff は、勝った文書で並びを置けたらその面を出す")
    XCTAssertEqual(
      dest.group.view.editor.shell.tabs.map(\.isDirty), [true, true, true, true], "未保存の印が割れない")
    XCTAssertEqual(dest.group.unsavedDocuments().count, 2, "確認は実体ごとに 1 件")
  }

  /// 行き先の同じ diff が文書を使っていない（見せていない間にファイルが消えて戻った）なら、元の diff だけが使っていた未保存の
  /// 文書を、行き先の diff が新しい側に使う——未保存の本文は確認なしに消えない。
  func testAnUnsavedDocumentOnlyTheMovedDiffUsedIsTakenByTheDestinationsDiff() throws {
    try repo.write("b.txt", "b\n")
    try FileManager.default.removeItem(at: repo.url("a.txt"))
    let (dest, _) = tab()
    let destDiff = try dest.group.editor.openDiff(id("a.txt", .workingTree), as: .pinned)
    try dest.group.editor.open(repo.url("b.txt"), as: .pinned)
    try repo.write("a.txt", "one\ntwo\nthree\nfour\n")
    let from = bareGroup()
    let edited = try from.editor.open(repo.url("a.txt"), as: .pinned)
    edited.surface.responder.perform(Selector(("insertText:")), with: "Z")
    try from.editor.openDiff(id("a.txt", .workingTree), as: .pinned)
    from.editor.close(.document(edited.url))
    XCTAssertNil(destDiff.document, "前提: 行き先の diff は文書を使っていない")

    dest.group.absorb(from)

    XCTAssertTrue(destDiff.document === edited, "行き先の diff が未保存の文書を使う")
    XCTAssertTrue(
      dest.group.unsavedDocuments().contains { $0 === edited }, "閉じれば失われる文書に数える")
  }
}
