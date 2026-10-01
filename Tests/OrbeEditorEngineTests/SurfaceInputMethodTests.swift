import AppKit
import OrbeEditorCore
import XCTest

@testable import OrbeEditorEngine

/// 面の IME——変換中の文字は打鍵と同じ道で文書に入り、IME が読み返す値は呼ぶたびに本文と一致し、undo には変換の
/// 終わりに正味の変化だけが 1 回載る。IME 以外の入口は先に変換を確定し、⌘Z は変換を取り消すだけ。壊れると字が重なる・
/// 消える・候補窓がずれる・⌘Z で読みが残る・履歴が本文とずれる。
@MainActor
final class SurfaceInputMethodTests: EngineTestCase {
  /// ライブ変換——未確定が 1 打鍵ごとに伸びて全体が置き換わり、変換して確定する。呼ぶたびに IME から見える状態が本文と
  /// 一致し、確定は 1 つの undo で戻る。
  func testLiveConversionStaysInStepWithTheText() throws {
    let opened = try open("let a = \n")
    _ = host(opened)
    fakeInputMethod(opened)
    opened.surface.selectedRange = NSRange(location: 8, length: 0)
    replay(
      [
        .mark("k"), .mark("か"), .mark("かn"), .mark("かな"),
        .mark("仮名", selected: NSRange(location: 0, length: 2)), .insert("仮名"),
      ], on: opened)
    XCTAssertEqual(text(opened.document), "let a = 仮名\n")
    XCTAssertEqual(opened.surface.caretLocation, 10)
    let undo = try XCTUnwrap(opened.surface.textView.undoManager)
    undo.undo()
    XCTAssertEqual(text(opened.document), "let a = \n", "確定は 1 回の undo で戻り、読みは履歴に出ない")
    XCTAssertFalse(undo.canUndo)
    undo.redo()
    XCTAssertEqual(text(opened.document), "let a = 仮名\n")
  }

  /// 確定した文字は前後の打鍵と同じまとまりに入り、打鍵 1 回で「確定 → 次の未確定」が来ても呼んだ順に反映され（IME が
  /// 呼び出しの間に読み返す値も最新）、描く材料は打鍵の後の 1 回だけ置かれる。
  func testCommitJoinsTheTypingAndTheNextCompositionFollowsInOneFrame() throws {
    let opened = try open("")
    _ = host(opened)
    let context = fakeInputMethod(opened)
    type(opened, "ab")
    replay([.mark("か")], on: opened)
    let revision = opened.surface.drawn.revision
    context.onEvent = { [self] client in
      client.insertText("か", replacementRange: IMECall.notFound)
      assertConsistent(opened, "確定の直後")
      client.setMarkedText(
        "き", selectedRange: NSRange(location: 1, length: 0), replacementRange: IMECall.notFound)
      assertConsistent(opened, "次の未確定の直後")
    }
    try key(opened, "k")
    XCTAssertEqual(opened.surface.drawn.revision, revision + 1, "描く材料は打鍵の後の 1 回")
    XCTAssertEqual(text(opened.document), "abかき")
    XCTAssertEqual(opened.surface.textView.markedRange(), NSRange(location: 3, length: 1))
    context.onEvent = nil
    replay([.insert("木")], on: opened)
    XCTAssertEqual(text(opened.document), "abか木")
    let undo = try XCTUnwrap(opened.surface.textView.undoManager)
    undo.undo()
    XCTAssertEqual(text(opened.document), "", "確定は前後の打鍵と同じまとまり")
    assertUndoRoundTrip(opened, first: "", last: "abか木")
  }

  /// IME が入れる文字列の改行（音声入力の改行など）は文書の作法（CRLF）に揃い、未確定の中の選択は揃えた後の同じ字の位置を
  /// 指す。
  func testInputMethodLineBreaksFollowTheDocument() throws {
    let opened = try open("a\r\n")
    _ = host(opened)
    fakeInputMethod(opened)
    opened.surface.selectedRange = NSRange(location: 1, length: 0)
    replay([.mark("x\ny", selected: NSRange(location: 3, length: 0))], on: opened)
    XCTAssertEqual(text(opened.document), "ax\r\ny\r\n")
    XCTAssertEqual(opened.surface.textView.markedRange(), NSRange(location: 1, length: 4))
    XCTAssertEqual(opened.surface.textView.selectedRange(), NSRange(location: 5, length: 0), "y の後")
    replay([.insert("p\nq")], on: opened)
    XCTAssertEqual(text(opened.document), "ap\r\nq\r\n")
  }

  /// 取り消し（空の未確定）で本文が元に戻れば、undo には何も載らない。
  func testCancellingLeavesNoUndo() throws {
    let opened = try open("x\n")
    _ = host(opened)
    fakeInputMethod(opened)
    replay([.mark("あ"), .mark("あい"), .mark("")], on: opened)
    XCTAssertEqual(text(opened.document), "x\n")
    XCTAssertFalse(opened.surface.textView.hasMarkedText())
    XCTAssertFalse(try XCTUnwrap(opened.surface.textView.undoManager).canUndo)
  }

  /// 再変換（確定済みの文字を置き換える）は前後で区切る——直前の打鍵とは別に戻る。
  func testReconversionIsItsOwnUndoElement() throws {
    let opened = try open("")
    _ = host(opened)
    fakeInputMethod(opened)
    type(opened, "かんじ")
    replay(
      [
        .mark("かんじ", replacement: NSRange(location: 0, length: 3)),
        .mark("漢字", selected: NSRange(location: 0, length: 2)), .insert("漢字"),
      ], on: opened)
    XCTAssertEqual(text(opened.document), "漢字")
    let undo = try XCTUnwrap(opened.surface.textView.undoManager)
    undo.undo()
    XCTAssertEqual(text(opened.document), "かんじ", "再変換だけが戻る")
    undo.undo()
    XCTAssertEqual(text(opened.document), "")
  }

  /// 変換の外で範囲を指した確定（長押しのアクセント）はその範囲を置き換え、前後で区切る。
  func testAccentReplacesTheTypedLetter() throws {
    let opened = try open("")
    _ = host(opened)
    fakeInputMethod(opened)
    type(opened, "cafe")
    replay([.insert("é", replacement: NSRange(location: 3, length: 1))], on: opened)
    XCTAssertEqual(text(opened.document), "café")
    XCTAssertEqual(opened.surface.caretLocation, 4)
    try XCTUnwrap(opened.surface.textView.undoManager).undo()
    XCTAssertEqual(text(opened.document), "cafe")
  }

  /// 変換中の ⌘Z / ⌘⇧Z は変換を取り消すだけで、それより前に確定した文字と undo の履歴に触れない。
  func testUndoWhileComposingCancelsOnly() throws {
    let opened = try open("")
    _ = host(opened)
    let context = fakeInputMethod(opened)
    type(opened, "ab")
    replay([.mark("か")], on: opened)
    opened.surface.textView.undo(nil)
    XCTAssertEqual(text(opened.document), "ab", "変換だけが消える")
    XCTAssertFalse(opened.surface.textView.hasMarkedText())
    XCTAssertEqual(context.discards, 1, "IME にも古い未確定を捨てさせる")
    replay([.mark("き")], on: opened)
    opened.surface.textView.redo(nil)
    XCTAssertEqual(text(opened.document), "ab")
    let undo = try XCTUnwrap(opened.surface.textView.undoManager)
    undo.undo()
    XCTAssertEqual(text(opened.document), "", "履歴は変換の前のまま")
  }

  /// IME 以外の入口（クリック・外からの選択・コマンド・保存・焦点の喪失・Esc）は、先に確定してから動き、IME に古い未確定を
  /// 捨てさせる。Esc は変換中なら上へ渡さない。
  func testOtherEntriesCommitFirst() throws {
    let opened = try open("one\ntwo\n")
    let window = host(opened)
    let context = fakeInputMethod(opened)
    var discards = 0
    func compose() { replay([.mark("あ")], on: opened) }
    func committed(_ expected: String, _ message: String) {
      XCTAssertFalse(opened.surface.textView.hasMarkedText(), message)
      XCTAssertEqual(text(opened.document), expected, message)
      discards += 1
      XCTAssertEqual(context.discards, discards, "\(message): IME に知らせる")
    }
    compose()
    try click(opened, row: 1, column: 1)
    committed("あone\ntwo\n", "クリック")
    compose()
    opened.surface.selectedRange = NSRange(location: 0, length: 0)
    committed("あone\ntあwo\n", "外からの選択")
    compose()
    opened.surface.perform(.move(.right, extending: false))
    committed("ああone\ntあwo\n", "コマンド")
    compose()
    try opened.document.save()
    committed("あああone\ntあwo\n", "保存")
    compose()
    opened.surface.textView.cancelOperation(nil)
    XCTAssertTrue(opened.surface.textView.hasMarkedText(), "Esc は変換中なら何もしない")
    window.makeFirstResponder(nil)
    committed("ああああone\ntあwo\n", "焦点の喪失")
  }

  /// 丸ごと置き換え（外部変更）は、変換を取り消してから置き換える。
  func testReplacingFromDiskCancelsTheComposition() throws {
    let opened = try open("a\n")
    _ = host(opened)
    fakeInputMethod(opened)
    replay([.mark("あ")], on: opened)
    opened.surface.replaceAll(with: "b\n")
    XCTAssertEqual(text(opened.document), "b\n")
    XCTAssertFalse(opened.surface.textView.hasMarkedText())
    try XCTUnwrap(opened.surface.textView.undoManager).undo()
    XCTAssertEqual(text(opened.document), "a\n", "読みは履歴に残らない")
  }

  /// IME の文節の選択は、配り先には選択として届かない（契約の選択と選択の知らせは未確定の末尾のキャレット）。
  func testTheInputMethodSelectionStaysInsideTheComposition() throws {
    let opened = try open("")
    _ = host(opened)
    fakeInputMethod(opened)
    var notified: [NSRange] = []
    let surface = opened.surface
    opened.document.onSelectionChange = { notified.append(surface.selectedRange) }
    replay([.mark("かなかな", selected: NSRange(location: 0, length: 2))], on: opened)
    XCTAssertEqual(opened.surface.textView.selectedRange(), NSRange(location: 0, length: 2))
    XCTAssertEqual(notified, [NSRange(location: 4, length: 0)])
    XCTAssertEqual(opened.surface.drawn.caret.carets, [], "文節を選んでいる間は主のキャレットを描かない")
    replay([.mark("かなかな", selected: NSRange(location: 1, length: 0))], on: opened)
    XCTAssertEqual(opened.surface.drawn.caret.carets, [1], "IME の注目位置のキャレット")
  }

  /// 変換中の ⌘ キーはまず IME へ渡る。渡している間にキー割り当てのコマンドが届けば IME は使わなかった（コマンドは実行
  /// しない）。IME が先に確定してからコマンドを返せば、確定した文字が入る。変換中でなければ IME へ渡さない。
  func testKeyEquivalentsGoToTheInputMethodFirst() throws {
    let opened = try open("ab\n")
    _ = host(opened)
    let context = fakeInputMethod(opened)
    let view = opened.surface.textView
    let key = try XCTUnwrap(
      NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0, windowNumber: 0,
        context: nil, characters: "z", charactersIgnoringModifiers: "z", isARepeat: false,
        keyCode: 6))
    XCTAssertFalse(view.offerKeyEquivalentToInputMethod(key))
    XCTAssertEqual(context.events, 0, "変換中でなければ渡さない")

    replay([.mark("か")], on: opened)
    context.onEvent = { $0.doCommand(by: #selector(NSResponder.moveLeft(_:))) }
    XCTAssertFalse(view.offerKeyEquivalentToInputMethod(key), "コマンドが届いた＝IME は使わなかった")
    XCTAssertEqual(opened.surface.caretLocation, 1, "届いたコマンドは実行しない")
    XCTAssertTrue(view.hasMarkedText())

    context.onEvent = {
      $0.setMarkedText(
        "かn", selectedRange: NSRange(location: 2, length: 0), replacementRange: IMECall.notFound)
    }
    XCTAssertTrue(view.offerKeyEquivalentToInputMethod(key), "IME が使った")
    XCTAssertEqual(text(opened.document), "かnab\n")

    context.onEvent = {
      $0.insertText("かん", replacementRange: IMECall.notFound)
      $0.doCommand(by: #selector(NSResponder.insertNewline(_:)))
    }
    XCTAssertFalse(view.offerKeyEquivalentToInputMethod(key))
    XCTAssertEqual(text(opened.document), "かんab\n", "確定した文字が入り、キーは呼び手の順で流れる")
    XCTAssertFalse(view.hasMarkedText())
  }

  /// 自動修正・置換・予測入力・Writing Tools は働かない。
  func testSubstitutionsAndPredictionsAreOff() throws {
    let opened = try open("")
    let view = opened.surface.textView
    for trait in [
      view.autocorrectionType, view.spellCheckingType, view.grammarCheckingType,
      view.smartQuotesType,
      view.smartDashesType, view.smartInsertDeleteType, view.textReplacementType,
      view.dataDetectionType, view.linkDetectionType, view.textCompletionType,
      view.inlinePredictionType,
    ] {
      XCTAssertEqual(trait, .no)
    }
    if #available(macOS 15.0, *) {
      XCTAssertEqual(view.writingToolsBehavior, .none)
      XCTAssertEqual(view.mathExpressionCompletionType, .no)
    }
  }

  /// 属性の無い未確定の文字は地で塗り、文節の属性があれば IME が選んでいる文節（太い下線）とそれ以外に分け、透明な下線の
  /// 色は指定が無いものとする。
  func testMarkedAppearanceFollowsTheAttributes() {
    let plain = MetalTextView.appearance(
      of: NSAttributedString(string: "かな"), selected: NSRange(location: 2, length: 0))
    XCTAssertEqual(plain, MarkedAppearance(clauses: [], filled: true))
    let clauses = NSMutableAttributedString(string: "漢字変換")
    clauses.addAttributes(
      [
        .markedClauseSegment: 0, .underlineStyle: NSUnderlineStyle.thick.rawValue,
        .underlineColor: NSColor.clear,
      ], range: NSRange(location: 0, length: 2))
    clauses.addAttributes(
      [.markedClauseSegment: 1, .underlineStyle: NSUnderlineStyle.single.rawValue],
      range: NSRange(location: 2, length: 2))
    let appearance = MetalTextView.appearance(
      of: clauses, selected: NSRange(location: 0, length: 2))
    XCTAssertEqual(
      appearance.clauses.map(\.range),
      [NSRange(location: 0, length: 2), NSRange(location: 2, length: 2)])
    XCTAssertEqual(appearance.clauses.map(\.active), [true, false])
    XCTAssertNil(appearance.clauses[0].underline, "透明な下線の色は指定が無いもの")
    XCTAssertFalse(appearance.filled)
  }

  /// 変換中の文字は本文と同じ 1 コマに描く——文節の下線（選んでいる文節は本文の色）と、属性の無い文字列の地。
  func testMarkedTextIsDrawnInTheSameFrame() throws {
    let opened = try open("\n")
    _ = host(opened, size: CGSize(width: 400, height: 80))
    fakeInputMethod(opened)
    let clauses = NSMutableAttributedString(string: "aaaa")
    clauses.addAttributes(
      [.markedClauseSegment: 0, .underlineStyle: NSUnderlineStyle.thick.rawValue],
      range: NSRange(location: 0, length: 2))
    clauses.addAttributes(
      [.markedClauseSegment: 1, .underlineStyle: NSUnderlineStyle.single.rawValue],
      range: NSRange(location: 2, length: 2))
    replay([.markAttributed(clauses, selected: NSRange(location: 0, length: 2))], on: opened)
    let config = opened.surface.config
    let column = config.columnWidth(lineCount: 2)
    let rowTop = (config.topInset * 2).rounded()
    let underline = Int((rowTop + (config.baseline * 2).rounded() + 3).rounded()) + 1
    let x = { (offset: Int) in
      Int(
        ((column + opened.surface.editingEnvironment()!.geometry.x(ofColumn: offset, row: 0)) * 2)
          .rounded())
    }
    let image = try XCTUnwrap(opened.surface.snapshot())
    XCTAssertEqual(
      Array(pixel(image, x: (x(0) + x(2)) / 2, y: underline).prefix(3)), [204, 204, 204],
      "選んでいる文節は本文の色")
    let other = pixel(image, x: (x(2) + x(4)) / 2, y: underline)
    XCTAssertGreaterThan(other[3], 0, "他の文節にも下線")
    XCTAssertLessThan(other[3], 255, "他の文節は灰色")
    XCTAssertEqual(pixel(image, x: x(2), y: underline)[3], 0, "文節の境は空ける")
    replay([.mark("aa")], on: opened)
    let filled = try XCTUnwrap(opened.surface.snapshot())
    let top = Int(rowTop) + 1
    XCTAssertGreaterThan(pixel(filled, x: (x(0) + x(2)) / 2, y: top)[3], 0, "属性の無い文字列は地で塗る")
  }
}
