import AppKit
import OrbeEditorCore
import XCTest

@testable import Orbe
@testable import OrbeEditorEngine

/// cd で連が畳まれるとき（`TabGroup.absorb`）の diff——元の連の diff は行き先へ移らず、元の連が消えた後に作業ツリーが変わって
/// も落ちない。同じファイルの文書は、開いている文書と行き先の Changes の diff の両側で 1 つに揃う。壊れると、元の連の解放後に
/// 作業ツリーが変わると落ちる・開いている文書と diff が別の文書を編集して未保存の印と確認が割れる。
extension EditorDiffTests {
  /// 窓に載せない連（畳まれる元の連）。
  private func bareGroup() -> TabGroup {
    TabGroup(key: repo.root, editorSurfaces: EditorSurfaces(queriesRoot: nil))
  }

  func testTheAbsorbedGroupsDiffIsNotCarriedAndItsGoingAwayIsSafe() throws {
    try repo.write("a.txt", "one\nTWO\nthree\nfour\n")
    try repo.write("b.txt", "b\n")
    let (dest, _) = tab()
    dest.group.editor.show(try dest.group.editor.open(repo.url("b.txt"), as: .pinned))
    weak var gone: TabGroup?
    weak var released: EditorDiff?
    try {
      let from = bareGroup()
      gone = from
      let diff = try from.editor.openDiff(id("a.txt", .workingTree))
      released = diff
      waitRows(diff, "元の連で見せている") { !$0.isEmpty }
      dest.group.absorb(from)
    }()
    XCTAssertNil(gone, "前提: 元の連は解放された")
    XCTAssertNil(released, "元の連の diff は手放される")
    XCTAssertNil(dest.group.editor.changesDiff, "行き先の Changes の diff は変わらない（Files の画面）")
    XCTAssertEqual(dest.group.editor.documents.map(\.url), [repo.url("b.txt")])
    try repo.write("a.txt", "one\nTWO\nthree\n")
    let files = RootFiles.shared(for: repo.root)
    pumpMain(until: { files.status?.badge(of: "a.txt") == .modified }, "元の連の解放後の書き換え")
  }

  /// 元の連で見せていた diff は畳みで見せるのをやめる——同じファイルを行き先の文書の本体で見せていれば、その面は
  /// コードの見え方のまま（diff の見え方が載らない）。
  func testAbsorbDoesNotCarryTheShownDiffsLookOntoTheDestinationsFileTab() throws {
    try repo.write("a.txt", "one\nTWO\nthree\nfour\n")
    let (dest, _) = tab()
    let document = try dest.group.editor.open(repo.url("a.txt"), as: .pinned)
    dest.group.editor.show(document)
    let from = bareGroup()
    let diff = try from.editor.openDiff(id("a.txt", .workingTree))
    waitRows(diff, "元の連で見せている") { !$0.isEmpty }

    dest.group.absorb(from)

    let surface = try engine(document.surface)
    XCTAssertEqual(surface.presentation, .code)
    XCTAssertTrue(surface.rows.isEmpty)
  }

  /// 勝つのは片側だけが未保存ならその側の文書（→ `EditorSession.adopt`）。行き先の Changes の diff も勝った文書を使う。
  func testAbsorbLeavesOneDocumentPerFileAcrossTheDocumentsAndTheDiff() throws {
    try repo.write("b.txt", "b\n")
    let (dest, _) = tab()
    let from = bareGroup()
    let b = try dest.group.editor.open(repo.url("b.txt"), as: .pinned)
    b.surface.responder.perform(Selector(("insertText:")), with: "m")
    let destDiff = try dest.group.editor.openDiff(id("a.txt", .workingTree))
    waitRows(destDiff, "行き先で見せている") { _ in true }
    let a = try from.editor.open(repo.url("a.txt"), as: .pinned)
    a.surface.responder.perform(Selector(("insertText:")), with: "t")

    dest.group.absorb(from)

    XCTAssertTrue(destDiff.document === a, "行き先の diff は元の未保存の文書を使う")
    XCTAssertEqual(dest.group.editor.documents.map(\.url), [b.url, a.url])
    pumpMain(
      until: { a.surface.view.isDescendant(of: dest.group.view.editor) },
      "見せている diff は、勝った文書で並びを置けたらその面を出す")
    XCTAssertEqual(dest.group.editor.documents.map(\.isDirty), [true, true], "未保存が割れない")
    XCTAssertEqual(dest.group.unsavedDocuments().count, 2, "確認は実体ごとに 1 件")
  }
}
