import Foundation
import OrbeEditorCore

/// カーソル 1 本の置換と、置換の後のキャレットの置き方。
struct Replacement {
  enum Caret {
    /// 入れた中身の終わり。
    case end
    /// 入れた中身を選ぶ。
    case selectInserted
  }

  var range: NSRange
  var text: ContiguousArray<UInt16>
  var caret = Caret.end

  init(_ range: NSRange, _ text: String, caret: Caret = .end) {
    self.range = range
    self.text = ContiguousArray(text.utf16)
    self.caret = caret
  }

  init(_ range: NSRange, units: ContiguousArray<UInt16>, caret: Caret = .end) {
    self.range = range
    text = units
    self.caret = caret
  }
}

/// 挿入と削除の規則。
extension EditCommands {
  /// カーソルごとの置換（nil は変えない）を束にし、置換の後のカーソルを置く。重なる置換は前のものを残す。どのカーソルも変え
  /// なければ、状態はそのまま（選択も undo のまとまりも保つ）。変えないカーソルは選択の両端を束に合わせてずらし（単位は文字
  /// に戻し、覚えた横位置は忘れる——VS Code が編集の後にカーソルを選択から置き直すのと同じ）、マークもずらす。
  static func edit(
    _ state: EditState, _ env: EditingEnvironment, undo: UndoKind,
    _ replace: (Cursor) -> Replacement?
  ) -> CommandResult {
    let cursors = state.cursors.all
    var planned: [(index: Int, replacement: Replacement)] = []
    for (index, cursor) in cursors.enumerated() {
      guard let replacement = replace(cursor) else { continue }
      planned.append((index, replacement))
    }
    planned.sort { $0.replacement.range.location < $1.replacement.range.location }
    var accepted: [(index: Int, replacement: Replacement)] = []
    for item in planned {
      if let last = accepted.last,
        item.replacement.range.location < NSMaxRange(last.replacement.range)
      {
        continue
      }
      accepted.append(item)
    }
    let batch = EditBatch(
      accepted.map { TextEdit(range: $0.replacement.range, replacement: $0.replacement.text) })
    guard !batch.isEmpty else { return CommandResult(state: state) }
    var result = cursors.map { cursor in
      Cursor(
        selectionStart: NSRange(location: batch.map(cursor.anchor), length: 0), unit: .character,
        position: batch.map(cursor.position))
    }
    var delta = 0
    for item in accepted {
      let replacement = item.replacement
      let start = replacement.range.location + delta
      let inserted = NSRange(location: start, length: replacement.text.count)
      result[item.index] =
        replacement.caret == .end ? Cursor(NSMaxRange(inserted)) : Cursor.selecting(inserted)
      delta += replacement.text.count - replacement.range.length
    }
    var list = CursorList(result[0], others: Array(result.dropFirst()))
    list.normalize()
    return CommandResult(
      state: EditState(cursors: list, mark: state.mark.map(batch.map)), edits: batch, undo: undo)
  }

  /// 各選択を `string` に置き換える（打鍵・ヤンク・タブ文字）。
  static func replaceSelections(
    with string: String, undo: UndoKind, _ state: EditState, _ env: EditingEnvironment
  ) -> CommandResult {
    edit(state, env, undo: undo) { Replacement($0.selection, string) }
  }

  /// 打鍵。空白 1 つは空白の打鍵、それ以外は字の打鍵。
  static func type(_ string: String, _ state: EditState, _ env: EditingEnvironment)
    -> CommandResult
  {
    replaceSelections(
      with: string, undo: string == " " ? .typing(.firstSpace) : .typing(.other), state, env)
  }

  /// 改行（VS Code の Enter の `autoIndent: keep` 相当）——字下げを引き継ぐなら、今の行の行頭の空白のうちキャレットより左を
  /// 文書の作法に揃えて続ける。
  static func newline(indents: Bool, _ state: EditState, _ env: EditingEnvironment)
    -> CommandResult
  {
    edit(state, env, undo: .newline) { cursor in
      let selection = cursor.selection
      guard indents else { return Replacement(selection, "\n") }
      let text = env.text
      let row = text.row(containing: selection.location)
      let start = text.lineStart(row)
      let leading = text.units(in: NSRange(location: start, length: selection.location - start))
        .prefix { $0 == 0x20 || $0 == 0x09 }
      return Replacement(
        selection, "\n" + Indenting.normalize(Array(leading), env.indentation))
    }
  }

  // MARK: - 削除

  /// 区間を消す（空の区間は変えない）。
  static func delete(
    _ state: EditState, _ env: EditingEnvironment, undo: UndoKind = .other,
    _ range: (Cursor) -> NSRange?
  ) -> CommandResult {
    edit(state, env, undo: undo) { cursor in
      guard let range = range(cursor), range.length > 0 else { return nil }
      return Replacement(range, "")
    }
  }

  /// ⌫（VS Code の `deleteLeft`、`useTabStops`）——選択があれば選択、字下げの空白の中なら前のタブ位置まで、そうでなければ
  /// macOS の後ろ向きの削除の単位 1 つ。
  static func deleteBackward(_ state: EditState, _ env: EditingEnvironment) -> CommandResult {
    delete(state, env, undo: .deletingLeft) { cursor in
      guard cursor.selection.length == 0 else { return cursor.selection }
      let text = env.text
      let position = cursor.position
      let row = text.row(containing: position)
      let start = text.lineStart(row)
      if position > start,
        let target = Indenting.previousTabStop(
          in: text.units(in: text.contentRange(ofRow: row)), column: position - start,
          size: env.indentation.unit)
      {
        return NSRange(location: start + target, length: position - start - target)
      }
      let from = text.backwardDeletionStart(before: position)
      return NSRange(location: from, length: position - from)
    }
  }

  /// ⌦——選択があれば選択、そうでなければ書記素 1 つ。
  static func deleteForward(_ state: EditState, _ env: EditingEnvironment) -> CommandResult {
    delete(state, env, undo: .deletingRight) { cursor in
      guard cursor.selection.length == 0 else { return cursor.selection }
      let end = env.text.nextBoundary(after: cursor.position)
      return NSRange(location: cursor.position, length: end - cursor.position)
    }
  }

  /// ⌃⌫（macOS の `deleteBackwardByDecomposingPreviousCharacter`）——前の字を分解し、最後の結合文字だけを消す（分解
  /// できない字はそのまま消す）。
  static func deleteDecomposing(_ state: EditState, _ env: EditingEnvironment) -> CommandResult {
    edit(state, env, undo: .deletingLeft) { cursor in
      guard cursor.selection.length == 0 else { return Replacement(cursor.selection, "") }
      guard cursor.position > 0 else { return nil }
      let cluster = env.text.grapheme(containing: cursor.position - 1)
      let range = NSRange(location: cluster.location, length: cursor.position - cluster.location)
      let decomposed = env.text.substring(range).decomposedStringWithCanonicalMapping
      let scalars = decomposed.unicodeScalars
      guard scalars.count > 1 else { return Replacement(range, "") }
      var kept = String.UnicodeScalarView()
      kept.append(contentsOf: scalars.dropLast())
      return Replacement(range, String(kept))
    }
  }

  /// ⌥⌫（VS Code の `deleteWordLeft`——`WordStart` で空白の特例つき）。空白が 2 つ以上続けばその並びを、そうでなければ
  /// 前の語の始まりまで、行頭なら前の改行を消す。
  static func deleteWordLeftRange(_ cursor: Cursor, _ text: TextRope) -> NSRange? {
    guard cursor.selection.length == 0 else { return cursor.selection }
    let position = cursor.position
    guard position > 0 else { return nil }
    let row = text.row(containing: position)
    let column = position - text.lineStart(row)
    guard column > 0 else {
      let end = NSMaxRange(text.contentRange(ofRow: row - 1))
      return NSRange(location: end, length: position - end)
    }
    let line = LineWindow(row: row, around: column, text)
    let local = line.local(column)
    let units = line.words.units
    let lastNonWhitespace = units[..<local].lastIndex { $0 != 0x20 && $0 != 0x09 } ?? -1
    if lastNonWhitespace + 1 < local - 1 {
      return NSRange(
        location: line.start + lastNonWhitespace + 1, length: local - lastNonWhitespace - 1)
    }
    let start = line.words.previousWord(before: local)?.start ?? 0
    return NSRange(location: line.start + start, length: local - start)
  }

  /// ⌥⌦（VS Code の `deleteWordRight`——`WordEnd` で空白の特例つき）。キャレットの後が空白なら空白の並びを、そうでなければ
  /// 次の語の終わりまで、行末なら改行と次の行の最初の語の前まで消す。
  static func deleteWordRightRange(_ cursor: Cursor, _ text: TextRope) -> NSRange? {
    guard cursor.selection.length == 0 else { return cursor.selection }
    let position = cursor.position
    guard position < text.length else { return nil }
    let row = text.row(containing: position)
    let content = text.contentRange(ofRow: row)
    let column = position - content.location
    let line = LineWindow(row: row, around: column, text)
    let local = line.local(column)
    let units = line.words.units
    let firstNonWhitespace = units[local...].firstIndex { $0 != 0x20 && $0 != 0x09 } ?? units.count
    if local < firstNonWhitespace {
      return NSRange(location: position, length: line.start + firstNonWhitespace - position)
    }
    if let word = line.words.nextWord(from: local) {
      return NSRange(location: position, length: line.start + word.end - position)
    }
    guard column == content.length, row + 1 < text.lineCount else {
      return NSRange(location: position, length: NSMaxRange(content) - position)
    }
    let next = LineWindow(row: row + 1, around: 0, text)
    let end = next.start + (next.words.nextWord(from: 0)?.start ?? next.words.units.count)
    return NSRange(location: position, length: end - position)
  }

  /// ⌘⌫（VS Code の `deleteAllLeft`）——選択があれば始まりの行頭から選択の終わりまで、1 列目なら前の改行、そうでなければ
  /// 行頭まで。
  static func lineStartRange(_ cursor: Cursor, _ text: TextRope) -> NSRange? {
    let selection = cursor.selection
    let row = text.row(containing: selection.location)
    let start = text.lineStart(row)
    if selection.length > 0 {
      return NSRange(location: start, length: NSMaxRange(selection) - start)
    }
    guard selection.location == start else {
      return NSRange(location: start, length: selection.location - start)
    }
    guard row > 0 else { return nil }
    let end = NSMaxRange(text.contentRange(ofRow: row - 1))
    return NSRange(location: end, length: start - end)
  }

  /// 行末まで（VS Code の `deleteAllRight`）——選択があれば選択、行末なら改行、そうでなければ行末まで。
  static func lineEndRange(_ cursor: Cursor, _ text: TextRope) -> NSRange? {
    let selection = cursor.selection
    guard selection.length == 0 else { return selection }
    let row = text.row(containing: selection.location)
    let end = NSMaxRange(text.contentRange(ofRow: row))
    guard selection.location == end else {
      return NSRange(location: selection.location, length: end - selection.location)
    }
    return NSRange(location: end, length: text.lineEnd(row) - end)
  }
}
