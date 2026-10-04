import Foundation
import OrbeEditorCore

/// 貼る・切り取る・落とすの規則（VS Code の `paste`・`cut`・`DragAndDropCommand`）。どれも前後で undo を区切る。
extension EditCommands {
  /// 貼る。カーソルへ配るなら（`ClipboardText.distribution`）、文書の順のカーソルの選択をそれぞれの文字列に置き換える。
  /// 行ごと写した文字列で条件が揃えば、各カーソルの行の上に行として入れ、カーソルは同じ字の位置のまま下がる（VS Code の
  /// `ReplaceCommandThatPreservesSelection`）。そうでなければ各選択を置き換える。キャレットはどれも入れた文字列の末尾。
  static func paste(
    _ string: String, entireLine: Bool, pieces: [String]?, _ state: EditState,
    _ env: EditingEnvironment
  ) -> CommandResult {
    if let parts = ClipboardText.distribution(
      string, pieces: pieces, entireLine: entireLine, cursors: state.cursors.count)
    {
      let order = state.cursors.all.map(\.selection.location).sorted()
      var part: [Int: String] = [:]
      for (location, text) in zip(order, parts) { part[location] = env.lineBreak.normalize(text) }
      return edit(state, env, undo: .other) { cursor in
        part[cursor.selection.location].map { Replacement(cursor.selection, $0) }
      }
    }
    let units = ContiguousArray(env.lineBreak.normalize(string).utf16)
    guard ClipboardText.pastesAboveLine(units, entireLine: entireLine, state.cursors) else {
      return edit(state, env, undo: .other) { Replacement($0.selection, units: units) }
    }
    let starts = Set(
      state.cursors.all.map { env.text.lineStart(env.text.row(containing: $0.position)) }
    ).sorted()
    let batch = EditBatch(
      starts.map { TextEdit(range: NSRange(location: $0, length: 0), replacement: units) })
    let shift = { (offset: Int) in
      var low = 0
      var high = starts.count
      while low < high {
        let mid = (low + high) / 2
        if starts[mid] <= offset { low = mid + 1 } else { high = mid }
      }
      return offset + units.count * low
    }
    return CommandResult(
      state: EditState(
        cursors: state.cursors.map { Cursor(shift($0.position)) }, mark: state.mark.map(shift)),
      edits: batch, undo: .other)
  }

  /// 切り取る——各選択を消す。選択が空なら VS Code の規則で行を消す（`ClipboardText.cutRange`）。
  static func cut(_ state: EditState, _ env: EditingEnvironment) -> CommandResult {
    delete(state, env) { ClipboardText.cutRange($0, env.text) }
  }

  /// 落とした文字列を `offset` に入れて選ぶ。`moving` があれば同じ束でその範囲を消す。
  static func drop(
    _ string: String, at offset: Int, moving: NSRange?, _ state: EditState,
    _ env: EditingEnvironment
  ) -> CommandResult {
    let insert = TextEdit(
      range: NSRange(location: offset, length: 0), replacement: env.lineBreak.normalize(string))
    let batch = EditBatch([insert] + (moving.map { [TextEdit(range: $0, replacement: "")] } ?? []))
    let index = batch.edits.firstIndex(of: insert) ?? 0
    return CommandResult(
      state: EditState(
        cursors: CursorList(.selecting(batch.newRanges[index])), mark: state.mark.map(batch.map)),
      edits: batch, undo: .other)
  }
}
