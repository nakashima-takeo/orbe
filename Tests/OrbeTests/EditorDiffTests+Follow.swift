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
    let diff = try tab.group.editor.openDiff(id("a.txt", .workingTree), as: .pinned)
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
    let document = try tab.group.editor.open(repo.url("a.txt"), as: .pinned)
    let diff = try tab.group.editor.openDiff(id("a.txt", .workingTree), as: .pinned)
    waitRows(diff, "変更が出る") { $0.boundaries == [1] }
    tab.group.editor.activate(document)
    let responder = document.surface.responder
    responder.perform(#selector(NSResponder.moveToBeginningOfDocument(_:)), with: nil)
    responder.perform(Selector(("insertText:")), with: "zero\n")
    XCTAssertEqual(document.text.lineCount, 6, "前提: 先頭に 1 行足した")

    tab.group.editor.activate(.diff(id("a.txt", .workingTree)))
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
    let diff = try tab.group.editor.openDiff(id("a.txt", .workingTree), as: .pinned)
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
    let diff = try tab.group.editor.openDiff(id("a.txt", .workingTree), as: .pinned)
    waitRows(diff, "変更が出る") { $0.boundaries == [1] }
    try FileManager.default.removeItem(at: repo.url("a.txt"))
    waitRows(diff, "消せば全部が削除") { self.removedLines($0) == [0, 1, 2, 3, 4] }
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
    let pane = tab.group.view.editor
    let diff = try tab.group.editor.openDiff(id("a.txt", .workingTree), as: .pinned)
    waitRows(diff, "変更が出る") { !$0.isEmpty }
    let surface = try engine(diff.newSurface)
    try Data([0xFF, 0xFE, 0x00, 0x01]).write(to: repo.url("a.txt"))
    XCTAssertTrue(repo.git(["add", "a.txt"]).isSuccess)
    pumpMain(until: { diff.content == .unavailable(.notText) }, "表示できなくなる")
    XCTAssertFalse(pane.emptyHost.isHidden)
    XCTAssertNil(surface.view.superview, "面は本体から外れる")
  }

  /// 未保存の間にファイルが消えても文書は手放さないが、未保存でなくなれば（undo で戻した）、見せ直した diff は作業ツリーの
  /// 今の姿（消えた）に戻る。
  func testADiffCatchesUpWithTheWorkingTreeOnceTheDocumentIsNoLongerUnsaved() throws {
    let (tab, _) = tab()
    let document = try tab.group.editor.open(repo.url("a.txt"), as: .pinned)
    let responder = document.surface.responder
    responder.perform(Selector(("insertText:")), with: "Z")
    let diff = try tab.group.editor.openDiff(id("a.txt", .workingTree), as: .pinned)
    waitRows(diff, "変更が出る") { !$0.isEmpty }
    try FileManager.default.removeItem(at: repo.url("a.txt"))
    pumpMain(until: { diff.files.status?.entries["a.txt"]?.unstaged == .deleted }, "消えた")
    XCTAssertTrue(diff.document === document, "前提: 未保存の間は手放さない")

    tab.group.editor.activate(document)
    try XCTUnwrap(responder.undoManager).undo()
    pumpMain(until: { !document.isDirty }, "undo で未保存でなくなる")
    tab.group.editor.activate(.diff(id("a.txt", .workingTree)))
    pumpMain(until: { diff.document == nil }, "消えたファイルの diff になる")
  }

  /// index が変わってステージ済み diff の新しい側が替わっても（並びの形は同じでも）、面は新しい index の本文を、同じ diff
  /// を開き直したのと同じ絵で描き、見えていた先頭の行を先頭に保つ（末尾が見えている位置でも）。
  func testAStagedDiffFollowsTheIndexAndKeepsTheTopLine() throws {
    var lines = (0..<200).map { "line \($0)" }
    try repo.write("long.txt", lines.joined(separator: "\n") + "\n")
    XCTAssertTrue(repo.git(["add", "-A"]).isSuccess)
    XCTAssertTrue(repo.git(["commit", "-qm", "long"]).isSuccess)
    lines[195] = "changed 195"
    try repo.write("long.txt", lines.joined(separator: "\n") + "\n")
    XCTAssertTrue(repo.git(["add", "long.txt"]).isSuccess)
    let (tab, _) = tab()
    let diff = try tab.group.editor.openDiff(id("long.txt", .staged), as: .pinned)
    waitRows(diff, "変更が出る") { !$0.isEmpty }
    let before = try engine(diff.newSurface)
    before.flush()
    let top = before.viewport.top.line
    XCTAssertGreaterThan(top, 0, "前提: 最初の変更区間へ送られている")
    let stale = try textPixels(before)  // 前の本文を一度描かせる（描いた行は面が持ち続ける）

    lines[195] = "again 195, now a longer line"
    let staged = lines.joined(separator: "\n") + "\n"
    try repo.write("long.txt", staged)
    XCTAssertTrue(repo.git(["add", "long.txt"]).isSuccess)
    pumpMain(
      until: { diff.newRevision?.text.contiguousUnits().count == staged.utf16.count },
      "新しい index の本文が届く")
    let after = try engine(diff.newSurface)
    after.flush()
    XCTAssertEqual(after.viewport.top.line, top)

    let (other, _) = self.tab()
    let fresh = try other.group.editor.openDiff(id("long.txt", .staged), as: .pinned)
    waitRows(fresh, "開き直した diff") { !$0.isEmpty }
    let freshSurface = try engine(fresh.newSurface)
    pumpMain(until: { freshSurface.viewport.top.line > 0 }, "面が大きさを持ち、最初の変更区間へ送られる")
    // 絵は同じ位置で比べる（送られる位置の端数は、開き方——最初の変更区間へ送るか、前の面の先頭の行を引き継ぐか——で違う）。
    for surface in [after, freshSurface] { surface.scroll(toFirstLine: CGFloat(top)) }
    let expected = try textPixels(freshSurface)
    XCTAssertTrue(stale != expected, "前提: 前の本文の絵とは違う")
    XCTAssertTrue(try textPixels(after) == expected, "開き直した diff と同じ絵")
  }

  /// 先頭の行の前の削除行を見ている間に index が変わってステージ済み diff の新しい側が替わっても、新しい面は削除行の頭から
  /// 見せる（先頭の行へ送り直して、削除行を上へ外さない）。インラインでも並列でも同じ。
  func testAStagedDiffFollowingTheIndexKeepsTheDeletionBeforeTheFirstLineInView() throws {
    let lines = (0..<200).map { "line \($0)" }
    try repo.write("head.txt", lines.joined(separator: "\n") + "\n")
    XCTAssertTrue(repo.git(["add", "-A"]).isSuccess)
    XCTAssertTrue(repo.git(["commit", "-qm", "long"]).isSuccess)
    var kept = Array(lines[100...])
    try repo.write("head.txt", kept.joined(separator: "\n") + "\n")
    XCTAssertTrue(repo.git(["add", "head.txt"]).isSuccess)
    let modes = EditorDiffModeState()
    let (tab, _) = tab()
    tab.group.view.editor.configure(
      translucency: ChromeTranslucency(), localization: LocalizationStore(language: .ja),
      fontResolver: ChromeFontResolver(), sidebar: EditorSidebarState(), diffModes: modes)
    for mode in [EditorDiff.Mode.inline, .side] {
      modes.select(mode)
      let diff = try tab.group.editor.openDiff(id("head.txt", .staged), as: .pinned)
      pumpMain(until: { diff.placement == .placed }, "\(mode): 最初の変更区間へ送る")
      let before = try engine(diff.newSurface)
      before.flush()
      XCTAssertEqual(before.viewportLines.first, 0, "前提: \(mode): 削除行の頭から見える")

      kept[90] = "changed \(mode)"
      let staged = kept.joined(separator: "\n") + "\n"
      try repo.write("head.txt", staged)
      XCTAssertTrue(repo.git(["add", "head.txt"]).isSuccess)
      pumpMain(
        until: {
          diff.newRevision?.text.contiguousUnits().count == staged.utf16.count
            && diff.carried == nil
        }, "\(mode): 新しい index の本文が届き、先頭を引き継ぐ")
      let after = try engine(diff.newSurface)
      XCTAssertFalse(after === before, "前提: \(mode): 面が作り直される")
      after.flush()
      XCTAssertLessThan(after.viewportLines.visible, 100, "前提: 削除行は見えている高さより長い")
      XCTAssertEqual(after.viewportLines.first, 0, "\(mode): 削除行の頭から見え続ける")
      tab.group.editor.close(.diff(id("head.txt", .staged)))
    }
  }

  /// インラインのステージ済み diff で削除行の塊の途中を読んでいる間に index が変わって面が作り直されても、同じ HEAD の行
  /// （読んでいた削除行の同じ段）が上端に残る——行 0 の前の塊でも、`git add` した箇所が読んでいる所より上で index の行の
  /// 数が変わっても。
  func testAStagedDiffKeepsTheRowBeingReadInsideTheRemovedLines() throws {
    let lines = (0..<300).map { "line \($0)" }
    try repo.write("long.txt", lines.joined(separator: "\n") + "\n")
    XCTAssertTrue(repo.git(["add", "-A"]).isSuccess)
    XCTAssertTrue(repo.git(["commit", "-qm", "long"]).isSuccess)
    var index = Array(lines[100..<150] + lines[250...])
    let (tab, _) = tab()
    let stage = { (text: [String]) in
      try self.repo.write("long.txt", text.joined(separator: "\n") + "\n")
      XCTAssertTrue(self.repo.git(["add", "long.txt"]).isSuccess)
    }
    try stage(index)
    let diff = try tab.group.editor.openDiff(id("long.txt", .staged), as: .pinned)
    pumpMain(until: { diff.placement == .placed && diff.newSurface != nil }, "最初の変更区間へ送る")
    struct Read {
      let top: RowPosition
      let change: (inout [String]) -> Void
      let expected: RowPosition
      let message: String
    }
    let reads = [
      Read(
        top: RowPosition(line: 0, offset: -50), change: { $0[20] = "below" },
        expected: RowPosition(line: 0, offset: -50), message: "行 0 の前の塊"),
      Read(
        top: RowPosition(line: 50, offset: -40),
        change: { $0.insert(contentsOf: ["x", "y", "z"], at: 10) },
        expected: RowPosition(line: 53, offset: -40), message: "上で 3 行増えた"),
    ]
    for read in reads {
      let (top, expected, message) = (read.top, read.expected, read.message)
      let before = try engine(diff.newSurface)
      before.scroll(to: top)
      before.flush()
      XCTAssertEqual(before.viewport.top, top, "前提: \(message) の途中を読む")
      read.change(&index)
      try stage(index)
      pumpMain(until: { diff.newSurface !== before && diff.carried == nil }, "\(message): 面が作り直される")
      let after = try engine(diff.newSurface)
      after.flush()
      XCTAssertEqual(after.viewport.top, expected, "\(message): 同じ HEAD の行が上端に残る")
    }
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

  /// 並列のまま、外の書き換えがずらしたハンクの形を崩す 2 通り（行の数を変えながら 2 区間をまたぐ・行の途中から末尾まで
  /// 消す）を受けても、並びは今の本文の中に収まり、左右の高さが揃う（落ちない）。
  func testSideBySideSurvivesExternalWritesAcrossHunks() throws {
    let cases = [
      ("a\nb\nc\nd\ne\nf\ng\nh\n", "a\nb\nC\nd\nE\nf\ng\nh\n", "a\nX\nC\nd\nE\nf\nY\nY2\nh\n"),
      ("a\nb\nX\nY", "a\nb\nc", "a\nb"),
    ]
    let (tab, _) = tab()
    tab.group.view.editor.configure(
      translucency: ChromeTranslucency(), localization: LocalizationStore(language: .ja),
      fontResolver: ChromeFontResolver(), sidebar: EditorSidebarState(),
      diffModes: EditorDiffModeState(mode: .side))
    for (index, (staged, working, written)) in cases.enumerated() {
      let path = "s\(index).txt"
      try repo.write(path, staged)
      XCTAssertTrue(repo.git(["add", path]).isSuccess)
      try repo.write(path, working)
      let diff = try tab.group.editor.openDiff(id(path, .workingTree), as: .pinned)
      pumpMain(until: { diff.content == .ready && diff.oldSurface != nil }, "並列")
      let document = try XCTUnwrap(diff.document)
      XCTAssertTrue(document.waitUntilCaughtUp())
      try repo.write(path, written)
      document.reconcileWithDisk()
      XCTAssertEqual(
        document.text.contiguousUnits().count, written.utf16.count, "前提: 結果が届く前に差し替わった")
      let (left, right) = (try engine(diff.oldSurface), try engine(diff.newSurface))
      let lines = try XCTUnwrap(diff.old).text.lineCount
      XCTAssertTrue(
        right.rows.boundaries.allSatisfy { $0 <= document.text.lineCount }, "右の差し込みは本文の中")
      XCTAssertEqual(
        left.rows.lastUnit(lineCount: lines),
        right.rows.lastUnit(lineCount: document.text.lineCount),
        "左右の高さが揃う: \(path)")
    }
  }

  /// 並列のまま作業ツリーのファイルが消えて新しい側の面が替わっても、左右の面はスクロールを共にし続ける。
  func testSideBySideKeepsSharingTheScrollWhenTheFileIsRemoved() throws {
    try repo.write("a.txt", "one\nTWO\nthree\nfour\n")
    let (tab, _) = tab()
    tab.group.view.editor.configure(
      translucency: ChromeTranslucency(), localization: LocalizationStore(language: .ja),
      fontResolver: ChromeFontResolver(), sidebar: EditorSidebarState(),
      diffModes: EditorDiffModeState(mode: .side))
    let diff = try tab.group.editor.openDiff(id("a.txt", .workingTree), as: .pinned)
    pumpMain(until: { diff.content == .ready && diff.oldSurface != nil }, "並列")
    try FileManager.default.removeItem(at: repo.url("a.txt"))
    pumpMain(until: { diff.document == nil && diff.oldSurface != nil }, "消えたファイルの並列")
    XCTAssertTrue(try engine(diff.oldSurface).partner === diff.newSurface as? MetalTextSurface)
  }

  /// 並列で左の面に焦点があるまま index が変わって左の面を作り直しても、焦点は作り直した左の面に残る（窓へ落ちず、右へも
  /// 移らない）。
  func testTheFocusStaysInTheDiffWhenTheLeftSurfaceIsRebuilt() throws {
    try repo.write("a.txt", "one\nTWO\nthree\nfour\n")
    let modes = EditorDiffModeState(mode: .side)
    let (tab, window) = tab()
    tab.group.view.editor.configure(
      translucency: ChromeTranslucency(), localization: LocalizationStore(language: .ja),
      fontResolver: ChromeFontResolver(), sidebar: EditorSidebarState(), diffModes: modes)
    let diff = try tab.group.editor.openDiff(id("a.txt", .workingTree), as: .pinned)
    pumpMain(until: { diff.content == .ready && diff.oldSurface != nil }, "並列")
    let left = try XCTUnwrap(diff.oldSurface).responder
    window.makeFirstResponder(left)
    try repo.write("a.txt", "one\nTWO\nthree\nFOUR\n")
    XCTAssertTrue(repo.git(["add", "a.txt"]).isSuccess)
    pumpMain(
      until: { diff.oldSurface.map { $0.responder !== left } ?? false }, "左の面が作り直される")
    XCTAssertTrue(window.firstResponder === diff.oldSurface?.responder, "焦点は最後に焦点のあった左の面に残る")
  }
}
