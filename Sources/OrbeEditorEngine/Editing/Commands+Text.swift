import Foundation
import OrbeEditorCore

/// キル・入れ替え・大小文字・マークの規則（macOS の NSTextView の意味。入れ替えは VS Code の `transposeLetters`）。
extension EditCommands {
  /// ⌃K（前へ：行末まで、行末なら改行）と行頭までのキル（後ろへ：1 列目なら前の改行）。選択があれば選択。消した文字列は
  /// キルバッファへ入れ、キルが続けば前へは後ろに、後ろへは前に足す。消すものが無ければキルバッファはそのまま。
  static func kill(forward: Bool, _ state: EditState, _ env: EditingEnvironment) -> CommandResult {
    let text = env.text
    let range = { (cursor: Cursor) -> NSRange? in
      if cursor.selection.length > 0 { return cursor.selection }
      return forward ? lineEndRange(cursor, text) : lineStartRange(cursor, text)
    }
    var result = delete(state, env, range)
    let killed = state.cursors.all.compactMap(range).map(text.substring).joined(separator: "\n")
    if !killed.isEmpty {
      result.kill =
        state.lastWasKill
        ? (forward ? env.killBuffer + killed : killed + env.killBuffer) : killed
    }
    return result
  }

  /// ⌃T——キャレットの前後の書記素を入れ替える。行末なら前の 2 つ。選択があれば何もしない。
  static func transpose(_ state: EditState, _ env: EditingEnvironment) -> CommandResult {
    let text = env.text
    return edit(state, env, undo: .other) { cursor in
      guard cursor.selection.length == 0 else { return nil }
      let position = cursor.position
      let row = text.row(containing: position)
      let lineEnd = NSMaxRange(text.contentRange(ofRow: row))
      guard position > 0,
        !(row == 0 && position == lineEnd && text.previousBoundary(before: position) == 0)
      else { return nil }
      let end = position == lineEnd ? position : text.nextBoundary(after: position)
      let middle = text.previousBoundary(before: end)
      let begin = text.previousBoundary(before: middle)
      guard begin < middle else { return nil }
      let left = text.units(in: NSRange(location: begin, length: middle - begin))
      let right = text.units(in: NSRange(location: middle, length: end - middle))
      return Replacement(NSRange(location: begin, length: end - begin), units: right + left)
    }
  }

  /// 語の入れ替え（macOS の `transposeWords:`）——キャレットの前の語と後ろの語（同じ行の通常の字の語）を入れ替え、
  /// キャレットは後ろの語の終わりへ。
  static func transposeWords(_ state: EditState, _ env: EditingEnvironment) -> CommandResult {
    let text = env.text
    return edit(state, env, undo: .other) { cursor in
      let row = text.row(containing: cursor.position)
      let line = LineWindow(row: row, around: cursor.position - text.lineStart(row), text)
      let column = line.local(cursor.position - text.lineStart(row))
      var before = line.words.previousWord(before: column)
      while let word = before, word.kind != .regular {
        before = line.words.previousWord(before: word.start)
      }
      var after = line.words.nextWord(from: max(column, before?.end ?? column))
      while let word = after, word.kind != .regular { after = line.words.nextWord(from: word.end) }
      guard let first = before, let second = after, first.end <= second.start else { return nil }
      let units = line.words.units
      let swapped =
        units[second.start..<second.end] + units[first.end..<second.start]
        + units[first.start..<first.end]
      return Replacement(
        NSRange(location: line.start + first.start, length: second.end - first.start),
        units: ContiguousArray(swapped))
    }
  }

  /// 大文字・小文字・先頭だけ大文字——選択があれば選択、無ければキャレットに接する通常の字の語。語が無ければ何もせず、
  /// 選択も元のまま。変えた後は変えた範囲を選ぶ。
  static func changeCase(_ change: CaseChange, _ state: EditState, _ env: EditingEnvironment)
    -> CommandResult
  {
    let text = env.text
    let target = { (cursor: Cursor) -> NSRange? in
      if cursor.selection.length > 0 { return cursor.selection }
      let range = wordRange(at: cursor.position, text)
      guard range.length > 0,
        LineWords.wordClass(text.unit(at: range.location) ?? 0x20) == .regular
      else { return nil }
      return range
    }
    return edit(state, env, undo: .other) { cursor in
      guard let range = target(cursor) else { return nil }
      let original = text.substring(range)
      let changed: String
      switch change {
      case .upper: changed = original.uppercased()
      case .lower: changed = original.lowercased()
      case .capitalize: changed = original.capitalized
      }
      return Replacement(range, changed, caret: .selectInserted)
    }
  }

  /// マーク（macOS の `setMark:` / `selectToMark:` / `deleteToMark:` / `swapWithMark:`。面ごと）。
  static func mark(_ command: EditCommand, _ state: EditState, _ env: EditingEnvironment)
    -> CommandResult
  {
    let caret = state.cursors.primary.position
    switch command {
    case .setMark:
      var next = state
      next.mark = caret
      return CommandResult(state: next, reveal: .none)
    case .selectToMark:
      guard let mark = state.mark else { return CommandResult(state: state, reveal: .none) }
      let cursor = Cursor(
        selectionStart: NSRange(location: mark, length: 0), unit: .character, position: caret)
      return CommandResult(state: EditState(cursors: CursorList(cursor), mark: mark))
    case .swapWithMark:
      guard let mark = state.mark else { return CommandResult(state: state, reveal: .none) }
      return CommandResult(state: EditState(cursors: CursorList(Cursor(mark)), mark: caret))
    default:
      guard let mark = state.mark else { return CommandResult(state: state, reveal: .none) }
      let range = NSRange(location: min(mark, caret), length: abs(mark - caret))
      var result = delete(state, env) { _ in range }
      if range.length > 0 { result.kill = env.text.substring(range) }
      return result
    }
  }
}
