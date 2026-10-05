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

  /// 続けて当てた束を 1 つに合成しても、当てた結果は同じ（打鍵のまとまり・⌫ の連続・離れた 2 か所・接する編集）。
  func testComposedBatchesEqualSequentialApplication() {
    var generator = SplitMix(seed: 0x5eed)
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

  private static func randomBatch(
    in text: TextRope, _ generator: inout SplitMix
  ) -> EditBatch {
    var edits: [TextEdit] = []
    var cursor = 0
    for _ in 0..<Int.random(in: 1...3, using: &generator) {
      guard cursor <= text.length else { break }
      let start = Int.random(in: cursor...text.length, using: &generator)
      var length = Int.random(in: 0...min(3, text.length - start), using: &generator)
      if let last = edits.last, last.range.length == 0, last.range.location == start, length == 0 {
        guard start < text.length else { break }
        length = 1
      }
      let replacement = String(repeating: "Z", count: Int.random(in: 0...3, using: &generator))
      edits.append(
        TextEdit(range: NSRange(location: start, length: length), replacement: replacement))
      cursor = start + length
    }
    return EditBatch(edits)
  }

  // MARK: - undo のまとめ方

  /// VS Code と同じ——単語と直前の空白 1 つがまとまり、空白が 2 つ続けばそこで切れる。Enter の前で切れ、後に続けて打った
  /// 字は同じまとまり。⌫・⌦ はそれぞれ続けてまとまり、行を結合する削除で切れる。「その他」は前後で切る。
  func testCoalescingFollowsVSCode() {
    func starts(_ previous: UndoKind?, _ next: UndoKind, joins: Bool = false) -> Bool {
      UndoCoalescing.startsNewElement(
        after: previous, UndoCoalescing.resolve(next, after: previous), joinsLines: joins)
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
  }

  /// 束の中の位置は、置き換わった区間の中なら置換の終わりへ寄せる（区間の外はずらす）——置換の中の同じ距離に写すと、中身の
  /// 変わった置換（⌃T・大小文字）で位置がサロゲートの対の中間に落ちうる。
  func testMapMovesPositionsInsideAReplacementToItsEnd() {
    let batch = EditBatch([edit(0, 3, "😀a"), edit(5, 1, "")])
    XCTAssertEqual(batch.map(0), 0, "区間の始まりは動かない")
    XCTAssertEqual(batch.map(1), 3, "区間の中は置換の終わり")
    XCTAssertEqual(batch.map(3), 3, "区間の終わりは置換の終わり")
    XCTAssertEqual(batch.map(4), 4)
    XCTAssertEqual(batch.map(7), 6, "後ろはずれる")
  }
}
