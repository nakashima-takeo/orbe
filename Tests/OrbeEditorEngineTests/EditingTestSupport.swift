import AppKit
import OrbeEditorCore
import XCTest

@testable import OrbeEditorEngine

/// 編集の規則（純関数）のテストの足場。本文と「|」で書いたキャレット（「[」「]」で書いた選択。`[` が動かない側）から
/// 状態を作り、コマンドを当てた結果を同じ書き方で返す。横位置は描画と同じ組版の規則（等幅の字の 1 桁は 12pt の SF Mono）。
@MainActor
enum Editing {
  static let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular) as CTFont
  static let cache = LineStopsCache(font: font)
  static var cell: CGFloat {
    LineShaper.shape(LineShaper.source(row: 0, in: TextRope(" ")).source, font: font, tabWidth: 0)
      .width
  }

  /// 「|」（キャレット）か「[」「]」（選択。`[` が動かない側、`]` がキャレット）を含む本文の、状態と本文。
  static func parse(_ marked: String) -> (TextRope, EditState) {
    var text = ""
    var anchor: Int?
    var caret = 0
    var offset = 0
    for character in marked {
      switch character {
      case "|": caret = offset
      case "[": anchor = offset
      case "]": caret = offset
      default:
        text.append(character)
        offset += character.utf16.count
      }
    }
    let cursor =
      anchor.map {
        Cursor(selectionStart: NSRange(location: $0, length: 0), unit: .character, position: caret)
      } ?? Cursor(caret)
    return (TextRope(text), EditState(cursors: CursorList(cursor)))
  }

  /// 状態を本文に書き戻す（`parse` の逆）。
  static func render(_ text: TextRope, _ state: EditState) -> String {
    let cursor = state.cursors.primary
    var units = Array(text.units(in: NSRange(location: 0, length: text.length)))
    if cursor.selection.length == 0 {
      units.insert(contentsOf: "|".utf16, at: cursor.position)
    } else {
      let (anchor, caret) = (cursor.anchor, cursor.position)
      units.insert(contentsOf: (anchor > caret ? "[" : "]").utf16, at: max(anchor, caret))
      units.insert(contentsOf: (anchor > caret ? "]" : "[").utf16, at: min(anchor, caret))
    }
    return String(decoding: units, as: UTF16.self)
  }

  static func environment(
    _ text: TextRope, indentation: Indentation = .fallback, lineBreak: LineBreak = .lf,
    pageLines: Int = 10, killBuffer: String = ""
  ) -> EditingEnvironment {
    EditingEnvironment(
      text: text,
      geometry: ShapedLineGeometry(
        text: text, cache: cache, tabWidth: CGFloat(indentation.unit) * cell),
      pageLines: pageLines, indentation: indentation, lineBreak: lineBreak, killBuffer: killBuffer)
  }

  /// コマンドを順に当て、最後の本文と状態を書いたもの。
  static func run(
    _ commands: [EditCommand], on marked: String, indentation: Indentation = .fallback,
    killBuffer: String = ""
  ) -> String {
    var (text, state) = parse(marked)
    var kill = killBuffer
    for command in commands {
      let result = EditCommands.run(
        command, state, environment(text, indentation: indentation, killBuffer: kill))
      text = result.edits.applied(to: text)
      state = result.state
      if let killed = result.kill { kill = killed }
    }
    return render(text, state)
  }

  static func run(
    _ command: EditCommand, on marked: String, indentation: Indentation = .fallback,
    killBuffer: String = ""
  ) -> String {
    run([command], on: marked, indentation: indentation, killBuffer: killBuffer)
  }
}
