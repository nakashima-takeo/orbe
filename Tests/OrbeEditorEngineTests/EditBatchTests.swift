import OrbeEditorCore
import XCTest

@testable import OrbeEditorEngine

/// 編集の束と undo のまとめ方（純関数）。壊れると、まとめた打鍵の undo が別の本文を戻す、束の逆が元の本文に戻らない、
/// VS Code と違う単位で ⌘Z が戻る。
final class EditBatchTests: XCTestCase {
  private func edit(_ location: Int, _ length: Int, _ text: String) -> TextEdit {
    TextEdit(range: NSRange(location: location, length: length), replacement: text)
  }

  private func string(_ rope: TextRope) -> String {
    rope.substring(NSRange(location: 0, length: rope.length))
  }

  func testInverseRestoresTheText() {
    let text = TextRope("abcdef")
    let batch = EditBatch([edit(1, 2, "XYZ"), edit(4, 0, "_"), edit(5, 1, "")])
    let after = batch.applied(to: text)
    XCTAssertEqual(string(after), "aXYZd_e")
    XCTAssertEqual(string(batch.inverse(of: text).applied(to: after)), "abcdef")
  }

  /// 続けて当てた束を 1 つに合成しても、当てた結果は同じ（打鍵のまとまり・⌫ の連続・離れた 2 か所）。
  func testComposedBatchesEqualSequentialApplication() {
    var generator = SystemRandomNumberGenerator()
    for _ in 0..<500 {
      let initial = TextRope(
        String(
          (0..<Int.random(in: 0...20, using: &generator)).map { _ in
            "ab \n".randomElement(using: &generator)!
          }))
      var text = initial
      var composed = EditBatch.empty
      for _ in 0..<Int.random(in: 1...6, using: &generator) {
        let batch = Self.randomBatch(in: text, &generator)
        text = batch.applied(to: text)
        composed = composed.then(batch, result: text)
      }
      XCTAssertEqual(string(composed.applied(to: initial)), string(text))
      XCTAssertEqual(string(composed.inverse(of: initial).applied(to: text)), string(initial))
    }
  }

  func testTypingComposesIntoOneEdit() {
    var text = TextRope("x")
    var composed = EditBatch.empty
    for (offset, character) in "abc".enumerated() {
      let batch = EditBatch([edit(1 + offset, 0, String(character))])
      text = batch.applied(to: text)
      composed = composed.then(batch, result: text)
    }
    XCTAssertEqual(composed.edits, [edit(1, 0, "abc")])
  }

  private static func randomBatch(
    in text: TextRope, _ generator: inout SystemRandomNumberGenerator
  ) -> EditBatch {
    var edits: [TextEdit] = []
    var cursor = 0
    for _ in 0..<Int.random(in: 1...3, using: &generator) {
      guard cursor <= text.length else { break }
      let start = Int.random(in: cursor...text.length, using: &generator)
      let length = Int.random(in: 0...min(3, text.length - start), using: &generator)
      let replacement = String(repeating: "Z", count: Int.random(in: 0...3, using: &generator))
      edits.append(
        TextEdit(range: NSRange(location: start, length: length), replacement: replacement))
      cursor = start + length + 1
    }
    return EditBatch(edits)
  }

  // MARK: - undo のまとめ方

  /// VS Code と同じ——単語と直前の空白 1 つがまとまり、空白が 2 つ続けばそこで切れる。Enter の前で切れ、後に続けて打った
  /// 字は同じまとまり。⌫・⌦ はそれぞれ続けてまとまり、行を結合する削除で切れる。「その他」は前後で切る。
  func testCoalescingFollowsVSCode() {
    func starts(_ previous: UndoKind?, _ next: UndoKind, joins: Bool = false) -> Bool {
      UndoCoalescing.startsNewElement(
        after: previous, UndoCoalescing.resolve(next, after: previous), joinsLines: joins,
        editCount: 1)
    }
    XCTAssertFalse(starts(.typing(.other), .typing(.other)))
    XCTAssertTrue(starts(.typing(.other), .typing(.firstSpace)), "語の後の空白で切る")
    XCTAssertFalse(starts(.typing(.firstSpace), .typing(.other)), "空白 1 つの後の字は同じまとまり")
    XCTAssertFalse(starts(.typing(.firstSpace), .typing(.firstSpace)), "続く空白")
    XCTAssertTrue(starts(.typing(.consecutiveSpace), .typing(.other)), "空白が 2 つ続けば切る")
    XCTAssertTrue(starts(.typing(.other), .newline), "Enter の前で切る")
    XCTAssertFalse(starts(.newline, .typing(.other)), "Enter の後に打った字は同じまとまり")
    XCTAssertFalse(starts(.deletingLeft, .deletingLeft))
    XCTAssertTrue(starts(.deletingLeft, .deletingLeft, joins: true), "行を結合する削除で切る")
    XCTAssertTrue(starts(.deletingLeft, .deletingRight))
    XCTAssertTrue(starts(.typing(.other), .deletingLeft))
    XCTAssertTrue(starts(.other, .typing(.other)))
    XCTAssertTrue(starts(nil, .typing(.other)))
    XCTAssertEqual(
      UndoCoalescing.resolve(.typing(.firstSpace), after: .typing(.firstSpace)),
      .typing(.consecutiveSpace))
    XCTAssertTrue(
      UndoCoalescing.startsNewElement(
        after: .typing(.other), .typing(.other), joinsLines: false, editCount: 2),
      "複数の編集を持つ束は切る")
  }
}
