import AppKit
import OrbeEditorCore
import XCTest

@testable import OrbeEditorEngine

/// 変換の終わり方と IME 以外の入口——取り消しは変換が無かったことにし、確定は IME 自身の終わりなら IME に知らせず、入口の
/// 確定は入口の仕事と 1 つの取引に入る。壊れると再変換中の ⌘Z で元の字が消える・確定した字が 2 回入る・中間のコマが出る。
extension SurfaceInputMethodTests {
  /// 再変換の途中の ⌘Z は変換が無かったことにする——置き換えた元の字が戻り、キャレットは変換の前へ戻り、undo の履歴は変換の
  /// 前のまま。
  func testUndoWhileReconvertingRestoresTheReplacedText() throws {
    let opened = try open("")
    _ = host(opened)
    fakeInputMethod(opened)
    type(opened, "かんじ")
    replay(
      [
        .mark("かんじ", replacement: NSRange(location: 0, length: 3)),
        .mark("漢字", selected: NSRange(location: 0, length: 2)),
      ], on: opened)
    opened.surface.textView.undo(nil)
    XCTAssertEqual(text(opened.document), "かんじ", "置き換えた元の字が戻る")
    XCTAssertFalse(opened.surface.textView.hasMarkedText())
    XCTAssertEqual(opened.surface.selectedRange, NSRange(location: 3, length: 0))
    let undo = try XCTUnwrap(opened.surface.textView.undoManager)
    undo.undo()
    XCTAssertEqual(text(opened.document), "", "履歴は打鍵の 1 要素だけ")
    XCTAssertFalse(undo.canUndo)
  }

  /// 選択の上で始めた変換の途中の ⌘Z は、選択していた字と選択を戻す。変換中の ⌘⇧Z も取り消すだけで、やり直しの履歴を
  /// 失わない。
  func testUndoWhileComposingOverASelectionRestoresIt() throws {
    let opened = try open("")
    _ = host(opened)
    fakeInputMethod(opened)
    type(opened, "xyz")
    opened.surface.selectedRange = NSRange(location: 0, length: 3)
    replay([.mark("か")], on: opened)
    XCTAssertEqual(text(opened.document), "か")
    opened.surface.textView.undo(nil)
    XCTAssertEqual(text(opened.document), "xyz")
    XCTAssertEqual(opened.surface.selectedRange, NSRange(location: 0, length: 3), "選択も戻る")
    let undo = try XCTUnwrap(opened.surface.textView.undoManager)
    undo.undo()
    XCTAssertEqual(text(opened.document), "", "履歴は変換の前のまま")
    XCTAssertFalse(undo.canUndo)
    replay([.mark("き")], on: opened)
    opened.surface.textView.redo(nil)
    XCTAssertEqual(text(opened.document), "")
    XCTAssertTrue(undo.canRedo, "やり直しの履歴を失わない")
  }

  /// 再変換の途中の外部変更は、変換を無かったことにしてから置き換える——1 回の undo で置き換えの前（再変換の前）へ戻る。
  func testReplacingFromDiskWhileReconvertingIsOneUndo() throws {
    let opened = try open("")
    _ = host(opened)
    fakeInputMethod(opened)
    type(opened, "かんじ")
    replay(
      [
        .mark("かんじ", replacement: NSRange(location: 0, length: 3)),
        .mark("漢字", selected: NSRange(location: 0, length: 2)),
      ], on: opened)
    opened.surface.replaceAll(with: "new\n")
    XCTAssertEqual(text(opened.document), "new\n")
    let undo = try XCTUnwrap(opened.surface.textView.undoManager)
    undo.undo()
    XCTAssertEqual(text(opened.document), "かんじ")
    undo.undo()
    XCTAssertEqual(text(opened.document), "")
  }

  /// `unmarkText` は未確定の文字を確定として残し、IME には変換を捨てさせない（IME 自身の終わり）。確定は 1 回の undo で戻る。
  func testUnmarkKeepsTheTextAsCommitted() throws {
    let opened = try open("")
    _ = host(opened)
    let context = fakeInputMethod(opened)
    replay([.mark("か"), .mark("かな"), .unmark], on: opened)
    XCTAssertEqual(text(opened.document), "かな")
    XCTAssertFalse(opened.surface.textView.hasMarkedText())
    XCTAssertEqual(context.discards, 0)
    let undo = try XCTUnwrap(opened.surface.textView.undoManager)
    undo.undo()
    XCTAssertEqual(text(opened.document), "")
  }

  /// IME に変換を捨てさせている間に IME が同期で返す確定・未確定は、終えた変換のものなので受けない——確定した字が 2 回
  /// 入らず、未確定も残らない。
  func testCallsWhileDiscardingAreIgnored() throws {
    let opened = try open("one\n")
    _ = host(opened)
    let context = fakeInputMethod(opened)
    replay([.mark("あ")], on: opened)
    context.onDiscard = { $0.insertText("あ", replacementRange: IMECall.notFound) }
    try click(opened, row: 0, column: 4)
    XCTAssertEqual(text(opened.document), "あone\n", "確定した字は 1 回だけ")
    replay([.mark("い")], on: opened)
    context.onDiscard = {
      $0.setMarkedText(
        "い", selectedRange: NSRange(location: 1, length: 0), replacementRange: IMECall.notFound)
    }
    opened.surface.selectedRange = NSRange(location: 0, length: 0)
    XCTAssertFalse(opened.surface.textView.hasMarkedText(), "捨てさせた後に未確定が残らない")
    XCTAssertEqual(text(opened.document).filter { $0 == "い" }.count, 1)
  }

  /// IME 以外の入口は、変換の確定と自分の仕事を 1 つの取引で行う（描く材料は 1 回だけ置く）。IME 自身の取り消しも 1 回。
  func testOtherEntriesCommitInTheSameTransaction() throws {
    let opened = try open("ab\n")
    _ = host(opened)
    fakeInputMethod(opened)
    let board = privatePasteboard(opened)
    board.declareTypes([.string], owner: nil)
    board.setString("z", forType: .string)
    let view = opened.surface.textView
    func once(_ message: String, _ body: () -> Void) {
      replay([.mark("か")], on: opened)
      let revision = opened.surface.material.read().revision
      body()
      XCTAssertFalse(view.hasMarkedText(), message)
      XCTAssertEqual(opened.surface.material.read().revision, revision + 1, message)
    }
    once("ペースト") { view.paste(nil) }
    once("カット") { view.cut(nil) }
    once("外からの選択") { opened.surface.selectedRange = NSRange(location: 0, length: 0) }
    once("コマンド") { opened.surface.perform(.move(.right, extending: false)) }
    once("丸ごと置き換え") { opened.surface.replaceAll(with: "cd\n") }
    once("IME 自身の取り消し") { replay([.mark("")], on: opened) }
  }

  /// 変換の外で本文の外を指した確定は、本文に収めた範囲を置き換える（キャレットと undo が本文とずれない）。
  func testInsertTextClampsTheReplacementRange() throws {
    let opened = try open("0123456789")
    _ = host(opened)
    fakeInputMethod(opened)
    replay([.insert("x", replacement: NSRange(location: 12, length: 0))], on: opened)
    XCTAssertEqual(text(opened.document), "0123456789x")
    XCTAssertEqual(opened.surface.caretLocation, 11)
    try XCTUnwrap(opened.surface.textView.undoManager).undo()
    XCTAssertEqual(text(opened.document), "0123456789")
  }
}
