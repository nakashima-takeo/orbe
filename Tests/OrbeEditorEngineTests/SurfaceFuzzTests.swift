import AppKit
import OrbeEditorCore
import XCTest

@testable import OrbeEditorEngine

/// 乱択の操作列——打鍵・削除・移動・字下げ・大小文字・キル・マウスの選択・外からの選択・undo / redo と、カーソルを増やす
/// 操作（⌘D・⌘⇧L・⌥⌘↑↓・⌥クリック・Esc）を何千手流しても、
/// 文書の写し・面の写し・選択とキャレットがどの時点でも本文の範囲に収まり、配り先が編集の列を順に畳んだ本文（行の増減
/// つき）が文書の本文と一致し続け、undo を尽くすと元の本文、redo を尽くすと履歴の先端の本文に戻る。壊れると「ある並びの
/// 操作でだけ」本文や選択がずれる、検索の一致やミニマップが本文からずれる。
///
/// IME の呼び出し（変換の始まり・続き・範囲を指した置き換え・確定・取り消し）を他の入口と混ぜて流しても（カーソルが複数の
/// 変換を含む）、IME から見える状態と全カーソルの未確定が本文と一致し続け、undo と redo を尽くすと元と先端の本文に戻る。
/// 壊れると「ある順の操作でだけ」未確定の範囲が本文とずれて字が重なる・消える、変換の取り消しや確定の後の undo が本文と
/// ずれて履歴が空になる。
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
    .move(.documentStart, extending: false), .selectLine, .selectWord, .addNextOccurrence,
    .addNextOccurrence, .selectAllOccurrences, .insertCursor(below: true),
    .insertCursor(below: false), .cancel,
  ]

  func testRandomOperationsKeepTheTextSelectionAndUndoConsistent() throws {
    for seed: UInt64 in [0x5eed, 6, 11] { try run(seed: seed, steps: 3000) }
  }

  func testRandomInputMethodCallsAmongOtherEntriesKeepTheTextAndUndoConsistent() throws {
    for seed: UInt64 in [0x1e, 7, 12] { try run(seed: seed, steps: 3000, inputMethod: true) }
  }

  private func run(seed: UInt64, steps: Int, inputMethod: Bool = false) throws {
    let original = "func a() {\n    let x = 1 // c\n\treturn x\n}\r\nend\n"
    let opened = try open(original, waitForColors: false)
    let window = host(opened)
    defer { window.contentView = nil }
    let undo = try XCTUnwrap(opened.surface.responder.undoManager)
    let view = opened.surface.textView
    if inputMethod {
      fakeInputMethod(opened)
      privatePasteboard(opened)
    }
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
      switch Int.random(in: 0..<(inputMethod ? 30 : 20), using: &generator) {
      case 0:
        view.undo(nil)
      case 1:
        view.redo(nil)
      case 2:
        let length = opened.document.text.length
        let a = Int.random(in: 0...length, using: &generator)
        let b = Int.random(in: 0...length, using: &generator)
        opened.surface.selectedRange = NSRange(location: min(a, b), length: abs(a - b))
      case 3:
        try click(
          opened, row: Int.random(in: 0...8, using: &generator),
          column: CGFloat(Int.random(in: 0...20, using: &generator)),
          clicks: Int.random(in: 1...3, using: &generator),
          flags: Bool.random(using: &generator) ? .option : [])
      case 20..<30:
        inputMethodStep(opened, window, &generator)
      default:
        opened.surface.editor.perform(Self.commands.randomElement(using: &generator)!)
      }
      try check(opened, "seed \(seed) step \(step)")
      XCTAssertEqual(shadow as String, text(opened.document), "seed \(seed) step \(step): 配り先の畳み")
      if inputMethod { assertConsistent(opened, "seed \(seed) step \(step)") }
      if !undo.canRedo && !view.hasMarkedText() { tip = text(opened.document) }
    }
    if view.hasMarkedText() {
      view.unmarkText()
      if !undo.canRedo { tip = text(opened.document) }
    }
    while undo.canUndo { undo.undo() }
    XCTAssertEqual(text(opened.document), original, "seed \(seed): undo を尽くすと元の本文")
    while undo.canRedo { undo.redo() }
    XCTAssertEqual(text(opened.document), tip, "seed \(seed): redo を尽くすと履歴の先端の本文")
  }

  private static let readings = ["k", "か", "かn", "かな", "漢字", "👍🏽", "é", " ", "x\ny"]

  /// IME の呼び出し 1 つか、変換を終わらせる IME 以外の入口 1 つ（カット・ペースト・焦点の喪失・丸ごと置き換え）。
  /// 範囲は IME が読み返す本文の字の境に置く。
  private func inputMethodStep(_ opened: Opened, _ window: NSWindow, _ generator: inout SplitMix) {
    let view = opened.surface.textView
    let text = opened.document.text
    func boundary() -> Int {
      let offset = Int.random(in: 0...text.length, using: &generator)
      return offset < text.length ? text.grapheme(containing: offset).location : offset
    }
    func range() -> NSRange {
      let (a, b) = (boundary(), boundary())
      return NSRange(location: min(a, b), length: abs(a - b))
    }
    let reading = Self.readings.randomElement(using: &generator)!
    let length = reading.utf16.count
    let at = Int.random(in: 0...length, using: &generator)
    let selected = NSRange(
      location: at, length: Int.random(in: 0...(length - at), using: &generator))
    switch Int.random(in: 0..<10, using: &generator) {
    case 0, 1, 2:
      view.setMarkedText(reading, selectedRange: selected, replacementRange: IMECall.notFound)
    case 3: view.setMarkedText(reading, selectedRange: selected, replacementRange: range())
    case 4: view.insertText(reading, replacementRange: IMECall.notFound)
    case 5: view.insertText(reading, replacementRange: range())
    case 6: view.unmarkText()
    case 7:
      view.setMarkedText(
        "", selectedRange: NSRange(location: 0, length: 0), replacementRange: IMECall.notFound)
    case 8:
      if Bool.random(using: &generator) { view.cut(nil) } else { view.paste(nil) }
    default:
      if Bool.random(using: &generator) {
        window.makeFirstResponder(nil)
        window.makeFirstResponder(view)
      } else {
        opened.surface.replaceAll(with: Self.readings.randomElement(using: &generator)! + "\n")
      }
    }
  }

  /// 位置の行（0 始まり）。
  private static func row(of offset: Int, in text: NSString) -> Int {
    var row = 0
    for i in 0..<offset where text.character(at: i) == 0x0A { row += 1 }
    return row
  }

  private func check(_ opened: Opened, _ step: String) throws {
    let length = opened.document.text.length
    let content = try XCTUnwrap(opened.surface.drawn.content)
    XCTAssertEqual(content.version, opened.document.version, "\(step): 面の写しは文書と同じ版")
    XCTAssertEqual(content.text.length, length)
    let caret = opened.surface.drawn.caret
    for cursor in opened.surface.editor.state.cursors.all {
      XCTAssertLessThanOrEqual(NSMaxRange(cursor.selection), length, "\(step)")
      XCTAssertLessThanOrEqual(NSMaxRange(cursor.selectionStart), length, "\(step)")
    }
    XCTAssertTrue(caret.carets.allSatisfy { $0 <= length }, "\(step)")
    XCTAssertTrue(caret.selections.allSatisfy { NSMaxRange($0) <= length }, "\(step)")
    let text = opened.document.text
    let marked = opened.surface.editor.composition?.marked.compactMap { $0 } ?? []
    let primary = opened.surface.editor.composition.map { text.units(in: $0.range) }
    for range in marked {
      XCTAssertLessThanOrEqual(NSMaxRange(range), length, "\(step)")
      XCTAssertEqual(text.units(in: range), primary, "\(step): どの未確定も主と同じ字")
    }
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
