import AppKit
import OrbeEditorCore
import XCTest

@testable import OrbeEditorEngine

/// 変換中のキーとメニュー——Esc は載せる側へ渡さず、取り消す・やり直すは変換の取り消しとして有効で、IME へ先に渡した
/// ⌘ キーの間の確定と次の未確定は 1 コマ。壊れると変換中の Esc で検索バーが閉じる・⌘Z がメニューで無効になり変換を
/// 取り消せない・中間のコマが出る・変換していない ⌘ キーのたびにコマを描き直す。
extension SurfaceInputMethodTests {
  /// 変換中の Esc は、IME が使わなければ上の responder へ渡さない（載せる側の検索バーを閉じない）。変換中でなければ渡す。
  func testEscapeWhileComposingDoesNotReachTheHost() throws {
    let opened = try open("ab\n")
    _ = host(opened)
    fakeInputMethod(opened)
    let view = opened.surface.textView
    let above = EscapeRecorder()
    above.nextResponder = view.nextResponder
    view.nextResponder = above
    replay([.mark("か")], on: opened)
    view.cancelOperation(nil)
    XCTAssertEqual(above.escapes, 0, "変換中は渡さない")
    XCTAssertTrue(view.hasMarkedText())
    replay([.insert("か")], on: opened)
    view.cancelOperation(nil)
    XCTAssertEqual(above.escapes, 1, "変換中でなければ渡す")
  }

  /// Edit メニューの取り消す・やり直すは、変換中なら履歴が無くても有効（⌘Z が変換の取り消しとして届く）。
  func testUndoAndRedoAreEnabledWhileComposing() throws {
    let opened = try open("")
    _ = host(opened)
    fakeInputMethod(opened)
    let view = opened.surface.textView
    func enabled(_ action: Selector) -> Bool {
      view.validateMenuItem(NSMenuItem(title: "", action: action, keyEquivalent: ""))
    }
    XCTAssertFalse(enabled(#selector(MetalTextView.undo(_:))))
    XCTAssertFalse(enabled(#selector(MetalTextView.redo(_:))))
    replay([.mark("か")], on: opened)
    XCTAssertTrue(enabled(#selector(MetalTextView.undo(_:))))
    XCTAssertTrue(enabled(#selector(MetalTextView.redo(_:))))
  }

  /// ⌘ キーを IME へ渡している間に IME が「確定 → 次の未確定」を返しても、描くのは 1 状態だけ。変換中でなければ ⌘ キーは
  /// 描く材料に触れない（コマを描き直さない）。
  func testKeyEquivalentsOfferedToTheInputMethodDrawOneFrame() throws {
    let opened = try open("ab\n")
    _ = host(opened)
    let context = fakeInputMethod(opened)
    let view = opened.surface.textView
    let key = try XCTUnwrap(
      NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0, windowNumber: 0,
        context: nil, characters: "j", charactersIgnoringModifiers: "j", isARepeat: false,
        keyCode: 38))
    var revision = opened.surface.material.read().revision
    XCTAssertFalse(view.offerKeyEquivalentToInputMethod(key))
    XCTAssertEqual(opened.surface.material.read().revision, revision, "変換中でなければ触れない")

    replay([.mark("か")], on: opened)
    context.onEvent = {
      $0.insertText("か", replacementRange: IMECall.notFound)
      $0.setMarkedText(
        "き", selectedRange: NSRange(location: 1, length: 0), replacementRange: IMECall.notFound)
    }
    revision = opened.surface.material.read().revision
    XCTAssertTrue(view.offerKeyEquivalentToInputMethod(key))
    XCTAssertEqual(text(opened.document), "かきab\n")
    XCTAssertEqual(opened.surface.material.read().revision, revision + 1, "描く材料は 1 回")
  }
}

/// 上の responder（載せる側）に届いた Esc を数える。
private final class EscapeRecorder: NSResponder {
  private(set) var escapes = 0

  override func cancelOperation(_ sender: Any?) { escapes += 1 }
}
