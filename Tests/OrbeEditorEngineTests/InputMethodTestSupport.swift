import AppKit
import OrbeEditorCore
import XCTest

@testable import OrbeEditorEngine

/// 偽の入力の仕組み。`handleEvent` で決めた呼び出しを受け手へ流し、IME へ届く知らせを数える。
final class FakeInputContext: NSTextInputContext {
  /// 出来事を受けたときに IME がすること（受け手を渡す）。
  var onEvent: ((NSTextInputClient) -> Void)?
  /// `handleEvent` の戻り値（IME が出来事を使ったか）。
  var consumes = false
  private(set) var events = 0
  private(set) var discards = 0
  private(set) var invalidations = 0

  override func handleEvent(_ event: NSEvent) -> Bool {
    events += 1
    onEvent?(client)
    return consumes
  }

  override func discardMarkedText() { discards += 1 }

  override func invalidateCharacterCoordinates() { invalidations += 1 }
}

/// IME の呼び出し 1 つ。範囲は NSTextInputClient と同じ（`selected` は文字列の中、`replacement` は文書の座標）。
enum IMECall {
  case mark(String, selected: NSRange? = nil, replacement: NSRange = notFound)
  case markAttributed(NSAttributedString, selected: NSRange)
  case insert(String, replacement: NSRange = notFound)
  case unmark

  static let notFound = NSRange(location: NSNotFound, length: 0)
}

@MainActor
extension EngineTestCase {
  /// 面の view に偽の IME を差し込む。
  @discardableResult
  func fakeInputMethod(_ opened: Opened) -> FakeInputContext {
    let context = FakeInputContext(client: opened.surface.textView)
    opened.surface.textView.textInputContext = context
    return context
  }

  /// IME の呼び出しを順に流す。呼ぶたびに、IME が読み返す値（未確定の範囲・選択・範囲の文字列）が本文と一致し続け、
  /// 未確定の中の選択が契約の選択（配り先が読む）へ漏れないことを確かめる。
  func replay(
    _ calls: [IMECall], on opened: Opened, file: StaticString = #filePath, line: UInt = #line
  ) {
    let client = opened.surface.textView
    for (index, call) in calls.enumerated() {
      switch call {
      case .mark(let string, let selected, let replacement):
        client.setMarkedText(
          string, selectedRange: selected ?? NSRange(location: string.utf16.count, length: 0),
          replacementRange: replacement)
      case .markAttributed(let string, let selected):
        client.setMarkedText(string, selectedRange: selected, replacementRange: IMECall.notFound)
      case .insert(let string, let replacement):
        client.insertText(string, replacementRange: replacement)
      case .unmark:
        client.unmarkText()
      }
      assertConsistent(opened, "呼び出し \(index)（\(call)）の後", file: file, line: line)
    }
  }

  /// IME から見える状態が本文と一致している。
  func assertConsistent(
    _ opened: Opened, _ message: String, file: StaticString = #filePath, line: UInt = #line
  ) {
    let client = opened.surface.textView
    let text = opened.document.text
    let selected = client.selectedRange()
    XCTAssertLessThanOrEqual(NSMaxRange(selected), text.length, message, file: file, line: line)
    guard client.hasMarkedText() else {
      XCTAssertEqual(client.markedRange().location, NSNotFound, message, file: file, line: line)
      XCTAssertEqual(selected, opened.surface.selectedRange, message, file: file, line: line)
      return
    }
    let marked = client.markedRange()
    XCTAssertLessThanOrEqual(NSMaxRange(marked), text.length, message, file: file, line: line)
    XCTAssertTrue(
      selected.location >= marked.location && NSMaxRange(selected) <= NSMaxRange(marked),
      "\(message): 選択は未確定の中", file: file, line: line)
    if marked.length > 0 {
      XCTAssertEqual(
        client.attributedSubstring(forProposedRange: marked, actualRange: nil)?.string,
        text.substring(marked), message, file: file, line: line)
    }
    XCTAssertEqual(
      opened.surface.selectedRange, NSRange(location: NSMaxRange(marked), length: 0),
      "\(message): 契約の選択は未確定の末尾のキャレット", file: file, line: line)
  }

  /// undo を尽くすと `first`、redo を尽くすと `last` に戻る。
  func assertUndoRoundTrip(
    _ opened: Opened, first: String, last: String, file: StaticString = #filePath,
    line: UInt = #line
  ) {
    guard let undo = opened.surface.textView.undoManager else { return XCTFail("undo が無い") }
    while undo.canUndo { undo.undo() }
    XCTAssertEqual(text(opened.document), first, "undo を尽くすと元の本文", file: file, line: line)
    while undo.canRedo { undo.redo() }
    XCTAssertEqual(text(opened.document), last, "redo を尽くすと最後の本文", file: file, line: line)
  }
}
