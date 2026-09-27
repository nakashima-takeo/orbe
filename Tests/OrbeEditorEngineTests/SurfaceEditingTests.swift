import AppKit
import OrbeEditorCore
import XCTest
import os

@testable import OrbeEditorEngine

/// 新しい面の編集と undo——打鍵・キー・⌘Z / ⌘⇧Z が文書の写しと undo に正しく載る。壊れると打鍵が文書に届かない、⌘Z の
/// まとまりが VS Code と違う、保存や外部変更の前の打鍵まで戻る、遠くの undo で本文が空になる、配り先が古い選択を読む。
@MainActor
final class SurfaceEditingTests: EngineTestCase {
  /// 打鍵・Enter・⌫ は macOS のキー割り当てを通って文書に届く。
  func testKeysEditTheDocument() throws {
    let opened = try open("let a = 1\n")
    _ = host(opened)
    opened.surface.selectedRange = NSRange(location: 9, length: 0)
    try key(opened, "2")
    try key(opened, "\r", keyCode: 36)
    try key(opened, "x")
    try key(opened, "\u{7f}", keyCode: 51)
    XCTAssertEqual(text(opened.document), "let a = 12\n\n")
    XCTAssertEqual(opened.surface.caretLocation, 11)
    try key(
      opened, String(UnicodeScalar(NSLeftArrowFunctionKey)!), [.option, .function], keyCode: 123)
    XCTAssertEqual(opened.surface.caretLocation, 8, "⌥← は前の行の語の始まりへ（VS Code の cursorWordLeft）")
    XCTAssertTrue(opened.document.isDirty)
  }

  /// ⌘Z は VS Code のまとめ方で戻る——語と直前の空白 1 つがまとまり、Enter の前で切れ、Enter の後に続けて打った字は同じ
  /// まとまり。⌘⇧Z で進み、戻した選択を置く。
  func testUndoGroupsLikeVSCode() throws {
    let opened = try open("")
    _ = host(opened)
    let undo = try XCTUnwrap(opened.surface.responder.undoManager)
    type(opened, "abc def")
    opened.surface.perform(.newline(indents: true))
    type(opened, "gh")
    undo.undo()
    XCTAssertEqual(text(opened.document), "abc def")
    undo.undo()
    XCTAssertEqual(text(opened.document), "abc")
    XCTAssertEqual(opened.surface.selectedRange, NSRange(location: 3, length: 0))
    undo.undo()
    XCTAssertEqual(text(opened.document), "")
    XCTAssertFalse(undo.canUndo)
    undo.redo()
    undo.redo()
    XCTAssertEqual(text(opened.document), "abc def")
    XCTAssertEqual(opened.surface.selectedRange, NSRange(location: 7, length: 0))
    type(opened, "!")
    XCTAssertFalse(undo.canRedo, "新しい編集で redo は消える")
  }

  /// カーソルの移動と保存は undo の区切り。未保存の印は ⌘Z で戻しても消えない。
  func testMovesAndSavesBreakTheUndoGroup() throws {
    let opened = try open("")
    _ = host(opened)
    let undo = try XCTUnwrap(opened.surface.responder.undoManager)
    type(opened, "ab")
    opened.surface.perform(.move(.left, extending: false))
    type(opened, "X")
    undo.undo()
    XCTAssertEqual(text(opened.document), "ab")
    type(opened, "Y")
    try opened.document.save()
    type(opened, "Z")
    undo.undo()
    XCTAssertEqual(text(opened.document), "aYb")
    XCTAssertTrue(opened.document.isDirty, "保存の後の編集を戻しても未保存のまま")
  }

  /// 中身を変えない編集（大文字の語の大文字化・同じ字での上書き）は文書へ渡さない——版も未保存の印も進まず、undo も積まない。
  func testEditsThatChangeNothingLeaveNoTrace() throws {
    let opened = try open("ABC abc\n")
    _ = host(opened)
    let undo = try XCTUnwrap(opened.surface.responder.undoManager)
    let version = opened.document.version
    opened.surface.selectedRange = NSRange(location: 0, length: 3)
    opened.surface.perform(.changeCase(.upper))
    XCTAssertEqual(opened.surface.selectedRange, NSRange(location: 0, length: 3), "変えた範囲を選ぶ")
    opened.surface.selectedRange = NSRange(location: 4, length: 1)
    type(opened, "a")
    XCTAssertEqual(opened.surface.selectedRange, NSRange(location: 5, length: 0))
    XCTAssertEqual(opened.document.version, version)
    XCTAssertFalse(opened.document.isDirty)
    XCTAssertFalse(undo.canUndo)
  }

  /// 外部変更の差し替えも undo に載り、前後で区切る。
  func testReplacingFromDiskIsUndoable() throws {
    let opened = try open("one\ntwo\n")
    _ = host(opened)
    let undo = try XCTUnwrap(opened.surface.responder.undoManager)
    opened.surface.selectedRange = NSRange(location: 3, length: 0)
    type(opened, "!")
    try Data("one\ntwo\nthree\n".utf8).write(to: opened.document.url)
    try opened.document.save(force: true)
    try Data("one\n2\nthree\n".utf8).write(to: opened.document.url)
    opened.document.reconcileWithDisk()
    XCTAssertEqual(text(opened.document), "one\n2\nthree\n")
    XCTAssertEqual(opened.surface.selectedRange.length, 0, "差し替えの後は選択が解ける")
    undo.undo()
    XCTAssertEqual(text(opened.document), "one!\ntwo\n", "差し替えだけが戻る")
    undo.undo()
    XCTAssertEqual(text(opened.document), "one\ntwo\n")
  }

  /// 遠くの行を編集した後にスクロールして戻り undo しても、本文は空にならず、その編集だけが戻る。
  func testUndoFarAwayRestoresOnlyThatEdit() throws {
    let original = (0..<3000).map { "line \($0)" }.joined(separator: "\n") + "\n"
    let opened = try open(original)
    _ = host(opened)
    let undo = try XCTUnwrap(opened.surface.responder.undoManager)
    let far = opened.document.text.lineStart(2500)
    opened.surface.selectedRange = NSRange(location: far, length: 0)
    type(opened, "far")
    opened.document.scroll(toFirstLine: 0)
    opened.surface.selectedRange = NSRange(location: 2, length: 0)
    type(opened, "near")
    undo.undo()
    XCTAssertEqual(opened.document.viewportLines.first, 0, accuracy: 1, "近くの undo は動かない")
    undo.undo()
    XCTAssertEqual(text(opened.document), original)
    XCTAssertEqual(opened.surface.selectedRange, NSRange(location: far, length: 0))
    let (first, visible) = opened.document.viewportLines
    XCTAssertTrue(first <= 2500 && 2500 < first + visible, "戻した場所が見える")
  }

  /// undo の要素が本文と一致しなければ（あってはならない）、本文に触れず、その面の undo を空にする。
  func testMismatchedUndoClearsTheHistoryWithoutTouchingTheText() throws {
    let opened = try open("abc\n")
    _ = host(opened)
    let undo = try XCTUnwrap(opened.surface.responder.undoManager)
    type(opened, "xyz")
    opened.document.surface(
      opened.surface,
      didChange: [TextEdit(range: NSRange(location: 0, length: 1), replacement: "Q")])
    opened.surface.rolesDidChange(IndexSet())
    undo.undo()
    XCTAssertEqual(text(opened.document), "Qyzabc\n")
    RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    XCTAssertFalse(undo.canUndo)
  }

  /// 本文の通知と選択の通知は、この順で届く（配り先は新しい本文で選択を読む）。取引 1 回で材料の箱へは 1 回だけ書く——
  /// 新しい本文と新しいキャレットが同じ版に入る。
  func testATransactionWritesOnceAndNotifiesTextThenSelection() throws {
    let opened = try open("let a = 1\n", waitForColors: true)
    _ = host(opened)
    opened.document.baseline = "let a = 1\n"
    XCTAssertTrue(opened.document.waitUntilCaughtUp())
    var order: [String] = []
    opened.document.onTextChange = { _ in order.append("text") }
    opened.document.onSelectionChange = {
      order.append("selection \(opened.surface.caretLocation) \(opened.document.text.length)")
    }
    let before = opened.surface.material.read().revision
    type(opened, "x")
    XCTAssertEqual(order, ["text", "selection 1 11"])
    let material = opened.surface.material.read()
    XCTAssertEqual(material.revision, before + 1, "写し・行の印・キャレットを 1 回で書く")
    XCTAssertEqual(material.content?.version, opened.document.version)
    XCTAssertEqual(material.caret.carets, [1])
  }

  /// 1 打鍵は 1 つの取引——セレクタが 2 つ届く ⌥↓（moveForward: と moveToEndOfParagraph:）でも材料の箱へは 1 回だけ
  /// 書き、途中の位置（1 字進んだだけのキャレット）のコマは出ない。打鍵の時刻は出来事の時刻を 1 つだけ添える。
  func testAKeystrokeIsOneTransaction() throws {
    let opened = try open("abc\ndef\n")
    _ = host(opened)
    _ = opened.surface.material.take()
    let before = opened.surface.material.revision
    let down: TimeInterval = 100
    try key(
      opened, String(UnicodeScalar(NSDownArrowFunctionKey)!), [.option, .function], keyCode: 125,
      timestamp: down)
    XCTAssertEqual(opened.surface.caretLocation, 3)
    XCTAssertEqual(opened.surface.material.revision, before + 1)
    let typed: TimeInterval = 100.25
    try key(opened, "x", timestamp: typed)
    let material = opened.surface.material.take()
    XCTAssertEqual(material.keystrokes, [down, typed], "打鍵ごとに出来事の時刻（移動の打鍵も打鍵→画面の遅れに数える）")
    XCTAssertEqual(text(opened.document), "abcx\ndef\n")
  }

  /// 編集の後に移動が続く打鍵（⌃O は insertNewlineIgnoringFieldEditor: と moveBackward:）も 1 つの取引——後のセレクタは
  /// 同じ打鍵で変わった本文の上で動き、材料の箱へは 1 回だけ書く（改行だけ入ってキャレットが次の行にあるコマは出ない）。
  func testAKeystrokeThatEditsThenMovesIsOneTransaction() throws {
    let opened = try open("abc\n")
    _ = host(opened)
    opened.surface.selectedRange = NSRange(location: 2, length: 0)
    let before = opened.surface.material.revision
    try key(opened, "o", .control, keyCode: 31)
    XCTAssertEqual(text(opened.document), "ab\nc\n")
    XCTAssertEqual(opened.surface.caretLocation, 2, "改行の前に残る")
    XCTAssertEqual(opened.surface.material.revision, before + 1)
    XCTAssertEqual(opened.surface.material.read().caret.carets, [2])
  }

  /// 取引は材料の版を先に決め、見せ方の位置をその版に結んでから材料を書く——材料を書く時点で位置は置いてあり、描画
  /// スレッドは新しい材料を読むまで前の位置を描く（新しい本文を古い位置で描くコマを出さない）。
  func testTheScrollIsPlacedBeforeTheMaterialIsWritten() throws {
    let opened = try open((0..<500).map { "row \($0)" }.joined(separator: "\n"))
    _ = host(opened, size: CGSize(width: 400, height: 200))
    let scroll = opened.surface.scroll
    let revision = opened.surface.material.revision
    let seen = OSAllocatedUnfairLock<(placed: Double, shown: Double)?>(initialState: nil)
    opened.surface.transact {
      opened.surface.perform(.move(.documentEnd, extending: false))
      opened.surface.write { _ in
        let placed = scroll.peek(at: 0).position.y
        let shown = scroll.frame(at: 0, material: revision).position.y
        seen.withLock { $0 = (placed, shown) }
      }
    }
    let (placed, shown) = try XCTUnwrap(seen.withLock { $0 })
    XCTAssertGreaterThan(placed, 0, "材料を書く前に、見せ方の位置は置いてある")
    XCTAssertEqual(shown, 0, "古い材料のコマは前の位置")
    XCTAssertEqual(opened.surface.material.revision, revision + 1)
    XCTAssertEqual(scroll.frame(at: 0, material: revision + 1).position.y, placed)
  }

  /// 打鍵の後の横の「見えるところまで」は、行を組む描画スレッドが解く——main は論理の位置だけを材料に添え、描画スレッドが
  /// キャレットの行を組んで横へ寄せ、見えている範囲を知らせ直す。
  func testTypingRevealsTheCaretHorizontallyOnTheRenderThread() throws {
    let opened = try open(String(repeating: "x", count: 300) + "\n")
    _ = host(opened, size: CGSize(width: 400, height: 120))
    opened.surface.selectedRange = NSRange(location: 300, length: 0)
    type(opened, "y")
    XCTAssertEqual(opened.surface.viewport.hiddenColumns, 0, "main は横に寄せない")
    _ = opened.surface.snapshot()
    pump(until: { opened.surface.viewport.hiddenColumns > 0 }, "描画スレッドが行の末尾まで寄せる")
    let viewport = opened.surface.viewport
    XCTAssertGreaterThanOrEqual(viewport.hiddenColumns + viewport.visibleColumns + 0.5, 301)
  }

  /// 描画スレッドは頼まれた横の「見えるところまで」を 1 度だけ解く——寄せた後に人が横へ戻せば、次のコマも戻したまま
  /// （同じ頼みで寄せ直さない）。次の打鍵はまた寄せる。
  func testTheHorizontalRevealIsSolvedOnce() throws {
    let opened = try open(String(repeating: "x", count: 300) + "\n")
    _ = host(opened, size: CGSize(width: 400, height: 120))
    opened.surface.selectedRange = NSRange(location: 300, length: 0)
    type(opened, "y")
    _ = opened.surface.snapshot()
    pump(until: { opened.surface.viewport.hiddenColumns > 0 }, "前提: 行の末尾まで寄せる")
    opened.surface.scroll(
      ScrollInput(timestamp: CACurrentMediaTime(), delta: SIMD2(100_000, 0), precise: true))
    XCTAssertEqual(opened.surface.viewport.hiddenColumns, 0, "前提: 人が行頭へ戻した")
    _ = opened.surface.snapshot()
    pump()
    _ = opened.surface.snapshot()
    XCTAssertEqual(opened.surface.viewport.hiddenColumns, 0, "戻したまま")
    type(opened, "z")
    _ = opened.surface.snapshot()
    pump(until: { opened.surface.viewport.hiddenColumns > 0 }, "次の打鍵はまた寄せる")
  }
}
