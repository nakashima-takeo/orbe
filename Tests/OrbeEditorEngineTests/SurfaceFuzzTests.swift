import AppKit
import OrbeEditorCore
import XCTest

@testable import OrbeEditorEngine

/// 乱択の操作列——打鍵・削除・移動・字下げ・大小文字・キル・マウスの選択・外からの選択・undo / redo を何千手流しても、
/// 文書の写し・面の写し・選択とキャレットがどの時点でも本文の範囲に収まり、配り先が編集の列を順に畳んだ本文（行の増減
/// つき）が文書の本文と一致し続け、undo を尽くすと元の本文、redo を尽くすと履歴の先端の本文に戻る。壊れると「ある並びの
/// 操作でだけ」本文や選択がずれる、検索の一致やミニマップが本文からずれる。
@MainActor
final class SurfaceFuzzTests: EngineTestCase {
  private static let commands: [EditCommand] = [
    .insert("a"), .insert(" "), .insert("é"), .insert("👍🏽"), .insert("\t"), .insert("日本"),
    .newline(indents: true), .newline(indents: false), .tab, .backtab, .indent, .literalTab,
    .deleteBackward, .deleteForward, .deleteBackwardDecomposing, .deleteWordBackward,
    .deleteWordForward, .deleteToLineStart, .deleteToLineEnd, .kill(forward: true),
    .kill(forward: false), .yank, .transpose, .transposeWords, .changeCase(.upper),
    .changeCase(.capitalize), .setMark, .selectToMark, .deleteToMark, .swapWithMark,
    .move(.left, extending: false), .move(.right, extending: true), .move(.up, extending: false),
    .move(.down, extending: true), .move(.wordLeft, extending: false),
    .move(.wordRight, extending: true), .move(.home, extending: false),
    .move(.end, extending: true), .move(.pageDown, extending: false),
    .move(.documentStart, extending: false), .selectLine, .selectWord,
  ]

  func testRandomOperationsKeepTheTextSelectionAndUndoConsistent() throws {
    for seed: UInt64 in [0x5eed, 6, 11] { try run(seed: seed, steps: 3000) }
  }

  private func run(seed: UInt64, steps: Int) throws {
    let original = "func a() {\n    let x = 1 // c\n\treturn x\n}\r\nend\n"
    let opened = try open(original, waitForColors: false)
    let window = host(opened)
    defer { window.contentView = nil }
    let undo = try XCTUnwrap(opened.surface.responder.undoManager)
    let shadow = NSMutableString(string: original)
    opened.document.onTextChange = { edits in
      for record in edits {
        let edit = record.edit
        XCTAssertEqual(Self.row(of: edit.range.location, in: shadow), record.start.row)
        XCTAssertEqual(Self.row(of: NSMaxRange(edit.range), in: shadow), record.oldEnd.row)
        shadow.replaceCharacters(
          in: edit.range,
          with: String(utf16CodeUnits: Array(edit.replacement), count: edit.replacementLength))
        XCTAssertEqual(Self.row(of: NSMaxRange(edit.newRange), in: shadow), record.newEnd.row)
      }
    }
    var generator = SplitMix(seed: seed)
    var tip = original
    for step in 0..<steps {
      switch Int.random(in: 0..<20, using: &generator) {
      case 0:
        undo.undo()
      case 1:
        undo.redo()
      case 2:
        let length = opened.document.text.length
        let a = Int.random(in: 0...length, using: &generator)
        let b = Int.random(in: 0...length, using: &generator)
        opened.surface.selectedRange = NSRange(location: min(a, b), length: abs(a - b))
      case 3:
        try click(
          opened, row: Int.random(in: 0...8, using: &generator),
          column: CGFloat(Int.random(in: 0...20, using: &generator)),
          clicks: Int.random(in: 1...3, using: &generator))
      default:
        opened.surface.perform(Self.commands.randomElement(using: &generator)!)
      }
      try check(opened, "seed \(seed) step \(step)")
      XCTAssertEqual(shadow as String, text(opened.document), "seed \(seed) step \(step): 配り先の畳み")
      if !undo.canRedo { tip = text(opened.document) }
    }
    while undo.canUndo { undo.undo() }
    XCTAssertEqual(text(opened.document), original, "seed \(seed): undo を尽くすと元の本文")
    while undo.canRedo { undo.redo() }
    XCTAssertEqual(text(opened.document), tip, "seed \(seed): redo を尽くすと履歴の先端の本文")
  }

  /// 位置の行（0 始まり）。
  private static func row(of offset: Int, in text: NSString) -> Int {
    var row = 0
    for i in 0..<offset where text.character(at: i) == 0x0A { row += 1 }
    return row
  }

  private func check(_ opened: Opened, _ step: String) throws {
    let length = opened.document.text.length
    let content = try XCTUnwrap(opened.surface.material.read().content)
    XCTAssertEqual(content.version, opened.document.version, "\(step): 面の写しは文書と同じ版")
    XCTAssertEqual(content.text.length, length)
    let caret = opened.surface.material.read().caret
    for cursor in opened.surface.editor.state.cursors.all {
      XCTAssertLessThanOrEqual(NSMaxRange(cursor.selection), length, "\(step)")
      XCTAssertLessThanOrEqual(NSMaxRange(cursor.selectionStart), length, "\(step)")
    }
    XCTAssertTrue(caret.carets.allSatisfy { $0 <= length }, "\(step)")
    XCTAssertTrue(caret.selections.allSatisfy { NSMaxRange($0) <= length }, "\(step)")
  }
}

/// 種から決まる乱数（失敗を再現できる）。
struct SplitMix: RandomNumberGenerator {
  private var state: UInt64

  init(seed: UInt64) {
    state = seed
  }

  mutating func next() -> UInt64 {
    state &+= 0x9E37_79B9_7F4A_7C15
    var z = state
    z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
    z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
    return z ^ (z >> 31)
  }
}
