import AppKit
import OrbeEditorCore
import XCTest

@testable import Orbe
@testable import OrbeEditorEngine

/// diff の追従——index・HEAD・作業ツリーの姿・ファイルタブでの編集が変わっても、並びは今の本文と古い側に付き、面は今の
/// 本文を描き、見えている行と焦点を保つ。
extension EditorDiffTests {
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

  /// 作業ツリー diff は開いた後の作業ツリーの姿に追従する——ファイルを消せば全部の行が削除、戻せば文書との差分、UTF-8 で
  /// ない中身になれば理由の一文。
  func testAWorkingTreeDiffFollowsTheFileBeingRemovedRestoredAndMadeBinary() throws {
    try repo.write("a.txt", "one\nTWO\nthree\nfour\n")
    let (tab, _) = tab()
    let diff = try tab.editor.openDiff(id("a.txt", .workingTree), as: .pinned)
    waitRows(diff, "変更が出る") { $0.boundaries == [1] }
    try FileManager.default.removeItem(at: repo.url("a.txt"))
    waitRows(diff, "消せば全部が削除") { self.removedLines($0) == [0, 1, 2, 3] }
    XCTAssertNil(diff.document)
    XCTAssertTrue(repo.git(["checkout", "--", "a.txt"]).isSuccess)
    waitRows(diff, "戻せば変更なし") { $0.isEmpty }
    XCTAssertNotNil(diff.document)
    try Data([0xFF, 0xFE, 0x00, 0x01]).write(to: repo.url("a.txt"))
    pumpMain(until: { diff.content == .unavailable(.notText) }, "UTF-8 でなくなれば表示できない")
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

  /// index が変わってステージ済み diff の新しい側が替わっても（並びの形は同じでも）、面は新しい index の本文を、同じ diff
  /// を開き直したのと同じ絵で描き、見えていた先頭の行を先頭に保つ。
  func testAStagedDiffFollowsTheIndexAndKeepsTheTopLine() throws {
    var lines = (0..<200).map { "line \($0)" }
    try repo.write("long.txt", lines.joined(separator: "\n") + "\n")
    XCTAssertTrue(repo.git(["add", "-A"]).isSuccess)
    XCTAssertTrue(repo.git(["commit", "-qm", "long"]).isSuccess)
    lines[120] = "changed 120"
    try repo.write("long.txt", lines.joined(separator: "\n") + "\n")
    XCTAssertTrue(repo.git(["add", "long.txt"]).isSuccess)
    let (tab, _) = tab()
    let diff = try tab.editor.openDiff(id("long.txt", .staged), as: .pinned)
    waitRows(diff, "変更が出る") { !$0.isEmpty }
    let before = try engine(diff.newSurface)
    before.flush()
    let top = try XCTUnwrap(diff.newRevision).text.row(containing: before.viewport.firstVisible)
    XCTAssertGreaterThan(top, 0, "前提: 最初の変更区間へ送られている")
    let stale = try textPixels(before)  // 前の本文を一度描かせる（描いた行は面が持ち続ける）

    lines[120] = "again 120, now a longer line"
    let staged = lines.joined(separator: "\n") + "\n"
    try repo.write("long.txt", staged)
    XCTAssertTrue(repo.git(["add", "long.txt"]).isSuccess)
    pumpMain(
      until: { diff.newRevision?.text.contiguousUnits().count == staged.utf16.count },
      "新しい index の本文が届く")
    let after = try engine(diff.newSurface)
    after.flush()
    XCTAssertEqual(diff.newRevision?.text.row(containing: after.viewport.firstVisible), top)

    let (other, _) = self.tab()
    let fresh = try other.editor.openDiff(id("long.txt", .staged), as: .pinned)
    waitRows(fresh, "開き直した diff") { !$0.isEmpty }
    let expected = try textPixels(try engine(fresh.newSurface))
    XCTAssertTrue(stale != expected, "前提: 前の本文の絵とは違う")
    XCTAssertTrue(try textPixels(after) == expected, "開き直した diff と同じ絵")
  }

  /// 面の絵の画素（縦スクロールバーの列を除く——つまみの見え方は時間で変わる）。
  private func textPixels(_ surface: MetalTextSurface) throws -> [UInt8] {
    surface.flush()
    let image = try XCTUnwrap(surface.snapshot())
    var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
    let context = try XCTUnwrap(
      CGContext(
        data: &bytes, width: image.width, height: image.height, bitsPerComponent: 8,
        bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    let width =
      Int(surface.surfaceLayout.verticalScrollbar.minX * CGFloat(image.width))
      / Int(surface.view.bounds.width)
    return (0..<image.height).flatMap { row in
      bytes[(row * image.width * 4)..<(row * image.width * 4 + width * 4)]
    }
  }

  /// 並列で左の面に焦点があるまま index が変わって左の面を作り直しても、焦点は diff の面に残る（窓へ落ちない）。
  func testTheFocusStaysInTheDiffWhenTheLeftSurfaceIsRebuilt() throws {
    try repo.write("a.txt", "one\nTWO\nthree\nfour\n")
    let modes = EditorDiffModeState(mode: .side)
    let (tab, window) = tab()
    tab.view.editor.configure(
      translucency: ChromeTranslucency(), localization: LocalizationStore(language: .ja),
      fontResolver: ChromeFontResolver(), sidebar: EditorSidebarState(), diffModes: modes)
    let diff = try tab.editor.openDiff(id("a.txt", .workingTree), as: .pinned)
    pumpMain(until: { diff.content == .ready && diff.oldSurface != nil }, "並列")
    let left = try XCTUnwrap(diff.oldSurface).responder
    window.makeFirstResponder(left)
    try repo.write("a.txt", "one\nTWO\nthree\nFOUR\n")
    XCTAssertTrue(repo.git(["add", "a.txt"]).isSuccess)
    pumpMain(
      until: { diff.oldSurface.map { $0.responder !== left } ?? false }, "左の面が作り直される")
    let focused = window.firstResponder
    XCTAssertTrue(
      focused === diff.oldSurface?.responder || focused === diff.newSurface?.responder,
      "焦点は diff の面に残る")
  }
}
