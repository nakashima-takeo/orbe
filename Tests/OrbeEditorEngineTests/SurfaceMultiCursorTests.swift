import AppKit
import OrbeEditorCore
import XCTest

@testable import OrbeEditorEngine

/// 面の複数カーソル——キーの表（key equivalent の段）・⌘U・Esc の順・全カーソルへの編集と undo・選択の知らせ。壊れると
/// ⌘D がサービスや端末に取られる・焦点の無い面で効く・⌘U がスクロールを戻さない・Esc で検索バーより先にカーソルが減る・
/// 打鍵が主にしか入らない・⌘Z でカーソルの並びが戻らない・主以外が動いても出現の強調が更新されない。
@MainActor
final class SurfaceMultiCursorTests: EngineTestCase {
  private func keyEquivalent(
    _ window: NSWindow, _ characters: String, _ flags: NSEvent.ModifierFlags
  ) throws -> Bool {
    let event = try XCTUnwrap(
      NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: flags, timestamp: CACurrentMediaTime(),
        windowNumber: window.windowNumber, context: nil, characters: characters,
        charactersIgnoringModifiers: characters, isARepeat: false, keyCode: 0))
    return window.performKeyEquivalent(with: event)
  }

  private func selections(_ opened: Opened) -> [NSRange] {
    opened.surface.cursorSelections
  }

  /// ⌘D・⌘⇧L・⌥⌘↓ は key equivalent の段で面の表から引き、面に焦点があるときだけ効く。
  func testMultiCursorKeysRunOnlyWhenTheSurfaceHasFocus() throws {
    let opened = try open("ab x ab\nab\n")
    let window = host(opened)
    opened.surface.selectedRange = NSRange(location: 1, length: 0)
    XCTAssertTrue(try keyEquivalent(window, "d", .command))
    XCTAssertEqual(selections(opened), [NSRange(location: 0, length: 2)])
    XCTAssertTrue(try keyEquivalent(window, "d", .command))
    XCTAssertEqual(
      selections(opened), [NSRange(location: 0, length: 2), NSRange(location: 5, length: 2)])
    XCTAssertTrue(try keyEquivalent(window, "L", [.command, .shift]))
    XCTAssertEqual(selections(opened).count, 3)
    let down = String(UnicodeScalar(NSDownArrowFunctionKey)!)
    opened.surface.selectedRange = NSRange(location: 1, length: 0)
    XCTAssertTrue(try keyEquivalent(window, down, [.command, .option, .function, .numericPad]))
    XCTAssertEqual(
      selections(opened), [NSRange(location: 1, length: 0), NSRange(location: 9, length: 0)])
    let up = String(UnicodeScalar(NSUpArrowFunctionKey)!)
    opened.surface.selectedRange = NSRange(location: 9, length: 0)
    XCTAssertTrue(try keyEquivalent(window, up, [.command, .option, .function, .numericPad]))
    XCTAssertEqual(
      selections(opened), [NSRange(location: 9, length: 0), NSRange(location: 1, length: 0)])
    XCTAssertTrue(try keyEquivalent(window, "u", .command))
    XCTAssertEqual(selections(opened), [NSRange(location: 9, length: 0)], "⌘U で足す前へ")

    let other = NSTextField()
    window.contentView?.addSubview(other)
    window.makeFirstResponder(other)
    opened.surface.selectedRange = NSRange(location: 1, length: 0)
    XCTAssertFalse(try keyEquivalent(window, "d", .command), "焦点が無ければ引かない")
    XCTAssertEqual(selections(opened), [NSRange(location: 1, length: 0)])
  }

  /// ⌘Z・⌘⇧Z は、本文とカーソルの列（数と主）をその時点へ戻す——主が文書の後ろにあっても主のまま。
  func testUndoAndRedoRestoreTheCursorListWithItsPrimary() throws {
    let opened = try open("abc abc\n")
    _ = host(opened)
    let surface = opened.surface
    surface.inputScope {
      surface.editor.select(CursorList(Cursor(4), others: [Cursor(0)]), reveal: .none)
    }
    type(opened, "x")
    XCTAssertEqual(selections(opened), [6, 1].map { NSRange(location: $0, length: 0) })
    surface.textView.cancelOperation(nil)
    XCTAssertEqual(selections(opened), [NSRange(location: 6, length: 0)])
    let undo = try XCTUnwrap(surface.responder.undoManager)
    undo.undo()
    XCTAssertEqual(text(opened.document), "abc abc\n")
    XCTAssertEqual(
      selections(opened), [4, 0].map { NSRange(location: $0, length: 0) }, "主が先頭のまま戻る")
    undo.redo()
    XCTAssertEqual(text(opened.document), "xabc xabc\n")
    XCTAssertEqual(selections(opened), [6, 1].map { NSRange(location: $0, length: 0) })
  }

  /// ⌘U は本文を変えないカーソルの変化を 1 つずつ戻し、そのときのスクロールの位置へ戻す。本文を変えると履歴は消える。
  func testCursorUndoStepsBackThroughCursorChanges() throws {
    let opened = try open(rows(200))
    _ = host(opened)
    let surface = opened.surface
    surface.selectedRange = NSRange(location: 0, length: 0)
    surface.editor.perform(.addNextOccurrence)
    surface.editor.perform(.addNextOccurrence)
    XCTAssertEqual(selections(opened).count, 2)
    let farAway = opened.document.text.lineStart(150)
    surface.inputScope { surface.editor.select(CursorList(Cursor(farAway)), reveal: .center) }
    let scrolled = surface.scrollPosition
    XCTAssertGreaterThan(scrolled.y, 0)
    surface.inputScope { surface.editor.undoCursors() }
    XCTAssertEqual(selections(opened).count, 2, "⌘D 2 回目の後へ")
    XCTAssertEqual(surface.scrollPosition.y, 0, "そのときのスクロールの位置へ")
    surface.inputScope { surface.editor.undoCursors() }
    XCTAssertEqual(selections(opened), [NSRange(location: 0, length: 3)])
    surface.editor.perform(.insert("z"))
    let afterEdit = selections(opened)
    surface.inputScope { surface.editor.undoCursors() }
    XCTAssertEqual(selections(opened), afterEdit, "本文を変えると履歴は消える")
  }

  /// Esc は先に載せる側へ問い（検索バーを閉じる）、使われなければカーソルを 1 本に戻し、次に選択を解く。
  func testEscapeAsksTheHostFirstThenCollapsesCursors() throws {
    let opened = try open("ab ab\n")
    _ = host(opened)
    let recorder = RecordingHost()
    opened.surface.host = recorder
    recorder.escapesToConsume = 1
    opened.surface.selectedRange = NSRange(location: 0, length: 2)
    opened.surface.editor.perform(.addNextOccurrence)
    let view = opened.surface.textView
    view.cancelOperation(nil)
    XCTAssertEqual(selections(opened).count, 2, "載せる側が使えば面は使わない")
    view.cancelOperation(nil)
    XCTAssertEqual(selections(opened), [NSRange(location: 0, length: 2)], "主の 1 本（選択は残す）")
    view.cancelOperation(nil)
    XCTAssertEqual(selections(opened), [NSRange(location: 2, length: 0)], "選択を解いて動く端へ")
    XCTAssertEqual(recorder.escapes, 3)
  }

  /// 主以外のカーソルだけが動いても、⌘D の続きが変わっても、選択の変化を知らせる。焦点を失えば続きは終わる。
  func testSelectionChangesOfAnyCursorAreAnnounced() throws {
    let opened = try open("ab ab ab\n")
    let window = host(opened)
    var announced = 0
    opened.document.onSelectionChange = { announced += 1 }
    opened.surface.selectedRange = NSRange(location: 0, length: 2)
    opened.surface.editor.perform(.addNextOccurrence)
    announced = 0
    let state = opened.surface.editor.state
    var others = state.cursors.others
    others[0] = Cursor(7)
    opened.surface.inputScope {
      opened.surface.editor.select(CursorList(state.cursors.primary, others: others), reveal: .none)
    }
    XCTAssertEqual(announced, 1, "主は動かず他が動いた")
    opened.surface.selectedRange = NSRange(location: 0, length: 2)
    announced = 0
    opened.surface.editor.perform(.addNextOccurrence)
    XCTAssertNotNil(opened.surface.searchContinuation)
    XCTAssertEqual(announced, 1)
    announced = 0
    window.makeFirstResponder(nil)
    XCTAssertNil(opened.surface.searchContinuation, "焦点を失えば続きは終わる")
    XCTAssertEqual(announced, 1)
  }
}
