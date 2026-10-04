import CoreGraphics
import Foundation
import OrbeEditorCore

/// 移動と選択の規則。
extension EditCommands {
  static func move(
    _ movement: Movement, extending: Bool, _ state: EditState, _ env: EditingEnvironment
  ) -> CommandResult {
    let alone = state.cursors.count == 1
    var cursors = state.cursors.map {
      move($0, movement, extending: extending, alone: alone, env)
    }
    cursors.normalize()
    let reveal: Reveal
    switch movement {
    case .pageUp: reveal = .page(-env.pageLines)
    case .pageDown: reveal = .page(env.pageLines)
    default: reveal = .minimal
    }
    return CommandResult(state: EditState(cursors: cursors, mark: state.mark), reveal: reveal)
  }

  /// カーソル 1 本の移動。`alone` はカーソルが 1 本だけか（⌥← の止まり方が変わる）。
  static func move(
    _ cursor: Cursor, _ movement: Movement, extending: Bool, alone: Bool,
    _ env: EditingEnvironment
  ) -> Cursor {
    let text = env.text
    let collapses = cursor.hasSelection && !extending
    switch movement {
    case .left:
      if collapses { return Cursor(cursor.selection.location) }
      return cursor.moved(to: text.previousBoundary(before: cursor.position), extending: extending)
    case .right:
      if collapses { return Cursor(NSMaxRange(cursor.selection)) }
      return cursor.moved(to: text.nextBoundary(after: cursor.position), extending: extending)
    case .up, .pageUp:
      return vertical(cursor, by: movement == .up ? -1 : -env.pageLines, extending: extending, env)
    case .down, .pageDown:
      return vertical(cursor, by: movement == .down ? 1 : env.pageLines, extending: extending, env)
    case .wordLeft:
      return cursor.moved(
        to: wordLeft(from: cursor.position, text, alone: alone), extending: extending)
    case .wordRight:
      return cursor.moved(to: wordRight(from: cursor.position, text), extending: extending)
    case .home:
      let row = text.row(containing: cursor.position)
      let first = firstNonWhitespace(ofRow: row, text) ?? text.lineStart(row)
      let target = cursor.position == first ? text.lineStart(row) : first
      return cursor.moved(to: target, extending: extending)
    case .end, .lineEnd:
      let row = text.row(containing: cursor.position)
      return cursor.moved(to: NSMaxRange(text.contentRange(ofRow: row)), extending: extending)
    case .lineStart:
      return cursor.moved(
        to: text.lineStart(text.row(containing: cursor.position)), extending: extending)
    case .paragraphBackward:
      return cursor.moved(to: paragraphBackward(from: cursor.position, text), extending: extending)
    case .paragraphForward:
      return cursor.moved(to: paragraphForward(from: cursor.position, text), extending: extending)
    case .documentStart:
      return cursor.moved(to: 0, extending: extending)
    case .documentEnd:
      return cursor.moved(to: text.length, extending: extending)
    }
  }

  /// ↑↓とページ送り（VS Code の `MoveOperations.vertical`）。横位置は覚えた x（無ければ今の位置の x）で、先頭の行より上は
  /// 文書の先頭、最終行より下は文書の末尾。選択があって伸ばさないなら、↑は始まり・↓は終わりから動く。
  private static func vertical(
    _ cursor: Cursor, by lines: Int, extending: Bool, _ env: EditingEnvironment
  ) -> Cursor {
    let text = env.text
    let from =
      cursor.hasSelection && !extending
      ? (lines < 0 ? cursor.selection.location : NSMaxRange(cursor.selection)) : cursor.position
    let row = text.row(containing: from)
    let x = cursor.desiredX ?? env.geometry.x(ofColumn: from - text.lineStart(row), row: row)
    let target = row + lines
    if target < 0 {
      return cursor.moved(to: 0, extending: extending, desiredX: from == 0 ? nil : x)
    }
    if target >= text.lineCount {
      let atEnd = from == text.length
      return cursor.moved(to: text.length, extending: extending, desiredX: atEnd ? nil : x)
    }
    let column = env.geometry.column(atX: x, row: target)
    return cursor.moved(to: text.lineStart(target) + column, extending: extending, desiredX: x)
  }

  /// ⌥←（VS Code の `cursorWordLeft`、`WordStartFast`）——前の語の始まりへ。カーソルが 1 本（`alone`）なら、1 字の区切りの
  /// 直前が通常の字のとき、その区切りを飛ばす（複数なら飛ばさず、カーソルごとに止まる所の種類をそろえる）。行頭なら前の行の
  /// 行末から探す。
  static func wordLeft(from offset: Int, _ text: TextRope, alone: Bool) -> Int {
    var row = text.row(containing: offset)
    var column = offset - text.lineStart(row)
    if column == 0, row > 0 {
      row -= 1
      column = text.contentRange(ofRow: row).length
    }
    let line = LineWindow(row: row, around: column, text)
    var word = line.words.previousWord(before: line.local(column))
    if alone, let found = word, found.kind == .separator, found.end - found.start == 1,
      found.nextClass == .regular
    {
      word = line.words.previousWord(before: found.start)
    }
    return line.start + (word?.start ?? line.local(0))
  }

  /// ⌥→（VS Code の `cursorWordEndRight`、`WordEnd`）——次の語の終わりへ。1 字の区切りの直後が通常の字なら、その区切りを
  /// 飛ばす。行末なら次の行の行頭から探す。
  static func wordRight(from offset: Int, _ text: TextRope) -> Int {
    var row = text.row(containing: offset)
    var column = offset - text.lineStart(row)
    if column == text.contentRange(ofRow: row).length, row + 1 < text.lineCount {
      row += 1
      column = 0
    }
    let line = LineWindow(row: row, around: column, text)
    var word = line.words.nextWord(from: line.local(column))
    if let found = word, found.kind == .separator, found.end - found.start == 1,
      found.nextClass == .regular
    {
      word = line.words.nextWord(from: found.end)
    }
    return line.start + (word?.end ?? line.words.units.count)
  }

  /// 行の最初の空白でない字（空白だけの行は nil）。
  static func firstNonWhitespace(ofRow row: Int, _ text: TextRope) -> Int? {
    let content = text.contentRange(ofRow: row)
    let units = text.units(in: content)
    return units.firstIndex { $0 != 0x20 && $0 != 0x09 }.map { content.location + $0 }
  }

  /// macOS の `moveParagraphBackward`——段落（行）の始まりへ。既に始まりなら前の行の始まり。
  private static func paragraphBackward(from offset: Int, _ text: TextRope) -> Int {
    let row = text.row(containing: offset)
    let start = text.lineStart(row)
    return offset == start && row > 0 ? text.lineStart(row - 1) : start
  }

  /// macOS の `moveParagraphForward`——段落（行）の終わりへ。既に終わりなら次の行の終わり。
  private static func paragraphForward(from offset: Int, _ text: TextRope) -> Int {
    let row = text.row(containing: offset)
    let end = NSMaxRange(text.contentRange(ofRow: row))
    return offset == end && row + 1 < text.lineCount
      ? NSMaxRange(text.contentRange(ofRow: row + 1)) : end
  }

  // MARK: - 語・行の選択

  /// 選択を行（改行まで）へ広げる（VS Code の `expandLineSelection`）。単位は行。
  static func lineSelection(_ cursor: Cursor, _ text: TextRope) -> Cursor {
    let rows = text.rows(of: cursor.selection)
    let range = NSRange(
      location: text.lineStart(rows.lowerBound),
      length: text.lineEnd(rows.upperBound) - text.lineStart(rows.lowerBound))
    return Cursor(selectionStart: range, unit: .line, position: NSMaxRange(range))
  }

  /// 位置の語を選ぶ（VS Code の `WordOperations.word` の初回）。通常の字の語に触れていればその語（語の終わりでは左を
  /// 優先）、区切りの並びの内側ならその並び、どちらでもなければ前後の語の間（空白の並び）。単位は語。
  static func wordSelection(at offset: Int, _ text: TextRope) -> Cursor {
    let range = wordRange(at: offset, text)
    return Cursor(selectionStart: range, unit: .word, position: NSMaxRange(range))
  }

  static func wordRange(at offset: Int, _ text: TextRope) -> NSRange {
    let row = text.row(containing: offset)
    let line = LineWindow(row: row, around: offset - text.lineStart(row), text)
    let column = line.local(offset - text.lineStart(row))
    let previous = line.words.previousWord(before: column)
    let next = line.words.nextWord(from: column)
    func touches(_ word: Word?, _ kind: WordKind) -> Word? {
      guard let word, word.kind == kind, word.start <= column else { return nil }
      return kind == .regular ? (column <= word.end ? word : nil) : (column < word.end ? word : nil)
    }
    if let word = touches(previous, .regular) ?? touches(previous, .separator)
      ?? touches(next, .regular) ?? touches(next, .separator)
    {
      return NSRange(location: line.start + word.start, length: word.end - word.start)
    }
    let start = previous?.end ?? 0
    let end = next?.start ?? line.words.units.count
    return NSRange(location: line.start + start, length: end - start)
  }

  /// 位置に接する通常の字の語（VS Code の `getWordAtPosition`——前の語を先に見る）。区切りと空白の上なら nil。
  static func regularWord(at offset: Int, _ text: TextRope) -> NSRange? {
    let row = text.row(containing: offset)
    let line = LineWindow(row: row, around: offset - text.lineStart(row), text)
    let column = line.local(offset - text.lineStart(row))
    for word in [line.words.previousWord(before: column), line.words.nextWord(from: column)] {
      guard let word, word.kind == .regular, word.start <= column, column <= word.end else {
        continue
      }
      return NSRange(location: line.start + word.start, length: word.end - word.start)
    }
    return nil
  }

  /// 語の単位のまま動く端を `offset` へ伸ばす（VS Code の `WordOperations.word` の選択中）——語の内側なら語の端へ揃え、
  /// 起点の範囲の中なら起点の範囲を保つ。
  static func extendByWord(_ cursor: Cursor, to offset: Int, _ text: TextRope) -> Cursor {
    let row = text.row(containing: offset)
    let line = LineWindow(row: row, around: offset - text.lineStart(row), text)
    let column = line.local(offset - text.lineStart(row))
    var bounds = NSRange(location: offset, length: 0)
    for word in [line.words.previousWord(before: column), line.words.nextWord(from: column)] {
      guard let word, word.kind == .regular, word.start < column, column < word.end else {
        continue
      }
      bounds = NSRange(location: line.start + word.start, length: word.end - word.start)
      break
    }
    let start = cursor.selectionStart
    func contains(_ x: Int) -> Bool { start.location <= x && x <= NSMaxRange(start) }
    var target: Int
    if contains(offset) {
      target = NSMaxRange(start)
    } else if offset <= start.location {
      target = bounds.location
      if contains(target) { target = NSMaxRange(start) }
    } else {
      target = NSMaxRange(bounds)
      if contains(target) { target = start.location }
    }
    return cursor.moved(to: target, extending: true)
  }

  /// 行の単位のまま動く端を行 `row` へ伸ばす（VS Code の `cursorMoveCommands.line` の選択中）——起点の行より上ならその行頭、
  /// 下なら次の行頭（最終行なら本文の終わり）、同じ行なら起点の範囲の終わり。
  static func extendByLine(_ cursor: Cursor, toRow row: Int, _ text: TextRope) -> Cursor {
    let entering = text.row(containing: cursor.selectionStart.location)
    let target =
      row < entering
      ? text.lineStart(row) : row > entering ? text.lineEnd(row) : NSMaxRange(cursor.selectionStart)
    return cursor.moved(to: target, extending: true)
  }
}

/// 語の規則が読む 1 行の窓。長い行ではキャレットの前後だけを読む（窓の端に掛かる語は窓で切れる）。窓の端は外側の書記素の
/// 境へ広げ、窓の中の位置が書記素を割らない。
struct LineWindow {
  static let maxLength = 2048
  /// 窓の始まり（本文のオフセット）。
  let start: Int
  /// 行頭から窓の始まりまで。
  let skipped: Int
  let words: LineWords

  init(row: Int, around column: Int, _ text: TextRope) {
    let content = text.contentRange(ofRow: row)
    var range = content
    if content.length > Self.maxLength {
      let from = min(max(0, column - Self.maxLength / 2), content.length - Self.maxLength)
      let lower = text.grapheme(containing: content.location + from).location
      let end = content.location + from + Self.maxLength
      let upper =
        end < NSMaxRange(content)
        ? min(NSMaxRange(text.grapheme(containing: end - 1)), NSMaxRange(content)) : end
      range = NSRange(location: lower, length: upper - lower)
    }
    start = range.location
    skipped = range.location - content.location
    words = LineWords(text.units(in: range))
  }

  /// 行頭からの距離を窓の中の距離へ（窓の外は窓の端）。
  func local(_ column: Int) -> Int {
    min(max(0, column - skipped), words.units.count)
  }
}
