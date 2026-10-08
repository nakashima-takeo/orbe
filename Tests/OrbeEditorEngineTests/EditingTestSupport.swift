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
      pageLines: pageLines, rows: RowLayout(lineHeight: 18), indentation: indentation,
      lineBreak: lineBreak, killBuffer: killBuffer)
  }

  /// コマンドを順に当て、最後の本文と状態を書いたもの。
  static func run(
    _ commands: [EditCommand], on marked: String, indentation: Indentation = .fallback,
    lineBreak: LineBreak = .lf, killBuffer: String = ""
  ) -> String {
    var (text, state) = parse(marked)
    var kill = killBuffer
    for command in commands {
      let result = EditCommands.run(
        command, state,
        environment(text, indentation: indentation, lineBreak: lineBreak, killBuffer: kill))
      text = result.edits.applied(to: text)
      state = result.state
      if let killed = result.kill { kill = killed }
    }
    return render(text, state)
  }

  static func run(
    _ command: EditCommand, on marked: String, indentation: Indentation = .fallback,
    lineBreak: LineBreak = .lf, killBuffer: String = ""
  ) -> String {
    run(
      [command], on: marked, indentation: indentation, lineBreak: lineBreak,
      killBuffer: killBuffer)
  }

  /// カーソルを何本でも書いた本文（「|」がキャレット、「[」「]」が選択で `[` が動かない側）の、本文と状態。列の並びは文書の
  /// 順で、`primary` 番目（文書の順）が主になって先頭に来る。
  static func parseAll(_ marked: String, primary: Int = 0) -> (TextRope, EditState) {
    var text = ""
    var cursors: [Cursor] = []
    var open: (character: Character, offset: Int)?
    var offset = 0
    for character in marked {
      switch character {
      case "|":
        cursors.append(Cursor(offset))
      case "[", "]":
        precondition(open?.character != character, "\(character) が閉じられないまま続いた: \(marked)")
        if let pending = open {
          let (anchor, caret) =
            character == "]" ? (pending.offset, offset) : (offset, pending.offset)
          cursors.append(
            Cursor(
              selectionStart: NSRange(location: anchor, length: 0), unit: .character,
              position: caret))
          open = nil
        } else {
          open = (character, offset)
        }
      default:
        text.append(character)
        offset += character.utf16.count
      }
    }
    precondition(open == nil, "閉じられていない選択: \(marked)")
    let first = cursors.remove(at: primary)
    return (TextRope(text), EditState(cursors: CursorList(first, others: cursors)))
  }

  /// 全カーソルを本文に書き戻す（`parseAll` の逆。主かどうかは書かない）。
  static func renderAll(_ text: TextRope, _ cursors: CursorList) -> String {
    struct Mark {
      let offset: Int
      let text: String
      /// 選択の始まりの印か（同じ位置の印は、選択の始まりを後ろに書く）。
      let starts: Bool
    }
    var units = Array(text.units(in: NSRange(location: 0, length: text.length)))
    var marks: [Mark] = []
    for cursor in cursors.all {
      if cursor.selection.length == 0 {
        marks.append(Mark(offset: cursor.position, text: "|", starts: false))
      } else {
        marks.append(Mark(offset: cursor.anchor, text: "[", starts: !cursor.isReversed))
        marks.append(Mark(offset: cursor.position, text: "]", starts: cursor.isReversed))
      }
    }
    let ordered = marks.sorted {
      $0.offset != $1.offset ? $0.offset > $1.offset : $0.starts && !$1.starts
    }
    for mark in ordered {
      units.insert(contentsOf: mark.text.utf16, at: mark.offset)
    }
    return String(decoding: units, as: UTF16.self)
  }

  /// コマンドを順に当て、最後の本文と全カーソルを書いたものと、最後の状態。
  static func runAll(_ commands: [EditCommand], on marked: String, primary: Int = 0) -> (
    String, EditState
  ) {
    var (text, state) = parseAll(marked, primary: primary)
    for command in commands {
      let result = EditCommands.run(command, state, environment(text))
      text = result.edits.applied(to: text)
      state = result.state
    }
    return (renderAll(text, state.cursors), state)
  }
}
