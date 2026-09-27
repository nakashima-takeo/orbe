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

  /// IME 自身の取り消し（空の未確定）は、再変換の途中でも未確定を消した本文のまま終える（NSTextView と同じ。置き換えた元の
  /// 字は戻さない）。その変化は確定済みの字を置き換えたものとして前後で区切り、1 回の undo で再変換の前へ戻る。
  func testTheInputMethodsOwnCancelWhileReconvertingKeepsTheTextAsOneUndo() throws {
    let opened = try open("")
    _ = host(opened)
    fakeInputMethod(opened)
    type(opened, "かんじ")
    replay(
      [
        .mark("かんじ", replacement: NSRange(location: 0, length: 3)),
        .mark("漢字", selected: NSRange(location: 0, length: 2)), .mark(""),
      ], on: opened)
    XCTAssertEqual(text(opened.document), "", "未確定を消した本文のまま")
    XCTAssertFalse(opened.surface.textView.hasMarkedText())
    let undo = try XCTUnwrap(opened.surface.textView.undoManager)
    undo.undo()
    XCTAssertEqual(text(opened.document), "かんじ", "再変換の前へ戻る")
    undo.undo()
    XCTAssertEqual(text(opened.document), "")
    XCTAssertFalse(undo.canUndo)
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

  /// IME 以外の入口は、変換の確定と自分の仕事を 1 つの取引で行い（描く材料は 1 回だけ置く）、IME に古い未確定を捨てさせる。
  /// IME 自身の終わり（確定・`unmarkText`・空の未確定）も 1 回で、IME には知らせない。
  func testOtherEntriesCommitInTheSameTransaction() throws {
    let opened = try open("ab\n")
    let window = host(opened)
    let context = fakeInputMethod(opened)
    let hostSide = RecordingHost()
    opened.surface.host = hostSide
    let board = privatePasteboard(opened)
    let view = opened.surface.textView
    func once(_ message: String, notifies: Bool = true, _ body: () throws -> Void) rethrows {
      board.declareTypes([.string], owner: nil)
      board.setString("z", forType: .string)
      replay([.mark("か")], on: opened)
      let revision = opened.surface.material.read().revision
      let discards = context.discards
      try body()
      XCTAssertFalse(view.hasMarkedText(), message)
      XCTAssertEqual(opened.surface.material.read().revision, revision + 1, message)
      XCTAssertEqual(context.discards, discards + (notifies ? 1 : 0), "\(message): IME に知らせる")
    }
    once("コピー") { view.copy(nil) }
    once("ペースト") { view.paste(nil) }
    once("カット") { view.cut(nil) }
    once("サービスへ送る") { _ = view.writeSelection(to: board, types: [.string]) }
    once("サービスの返し") { _ = view.readSelection(from: board) }
    try once("右クリック") {
      _ = view.menu(
        for: try XCTUnwrap(
          NSEvent.mouseEvent(
            with: .rightMouseDown,
            location: view.convert(point(opened, row: 0, column: 0), to: nil), modifierFlags: [],
            timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0,
            clickCount: 1, pressure: 1)))
    }
    once("ドロップ") {
      _ = view.performDragOperation(
        FakeDraggingInfo(
          at: view.convert(point(opened, row: 0, column: 0), to: nil), pasteboard: board,
          operations: .copy))
    }
    once("外からの選択") { opened.surface.selectedRange = NSRange(location: 0, length: 0) }
    once("コマンド") { opened.surface.perform(.move(.right, extending: false)) }
    once("丸ごと置き換え") { opened.surface.replaceAll(with: "cd\n") }
    once("IME の確定", notifies: false) { replay([.insert("か")], on: opened) }
    once("IME の unmarkText", notifies: false) { replay([.unmark], on: opened) }
    once("IME 自身の取り消し", notifies: false) { replay([.mark("")], on: opened) }
  }

  /// 文書を切り替えて面が窓から外れると、変換を確定して IME に知らせる（新しい面は変換を文書ごとに残さない）。
  func testLeavingTheWindowCommitsTheComposition() throws {
    let opened = try open("ab\n")
    let window = host(opened)
    let context = fakeInputMethod(opened)
    replay([.mark("か")], on: opened)
    window.contentView = nil
    XCTAssertFalse(opened.surface.textView.hasMarkedText())
    XCTAssertEqual(text(opened.document), "かab\n")
    XCTAssertEqual(context.discards, 1)
  }

  /// 確定済みの字を置き換えた変換は、正味の変化が挿入だけでも前後で区切る（直前の打鍵と一緒に戻らない）。
  func testReplacingCommittedTextIsItsOwnUndoEvenWhenOnlyAppending() throws {
    let opened = try open("")
    _ = host(opened)
    fakeInputMethod(opened)
    type(opened, "ab")
    replay(
      [.mark("abc", replacement: NSRange(location: 0, length: 2)), .insert("abc")], on: opened)
    XCTAssertEqual(text(opened.document), "abc")
    let undo = try XCTUnwrap(opened.surface.textView.undoManager)
    undo.undo()
    XCTAssertEqual(text(opened.document), "ab", "変換だけが戻る")
  }

  /// 確定を undo すると、キャレットと選択は変換が始まる前へ戻る（選択の上で始めた変換なら、その選択）。
  func testUndoingACommitRestoresTheSelectionBeforeTheComposition() throws {
    let opened = try open("xyz\n")
    _ = host(opened)
    fakeInputMethod(opened)
    opened.surface.selectedRange = NSRange(location: 1, length: 2)
    replay([.mark("か"), .mark("かな"), .insert("仮名")], on: opened)
    XCTAssertEqual(text(opened.document), "x仮名\n")
    try XCTUnwrap(opened.surface.textView.undoManager).undo()
    XCTAssertEqual(text(opened.document), "xyz\n")
    XCTAssertEqual(opened.surface.selectedRange, NSRange(location: 1, length: 2))
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
