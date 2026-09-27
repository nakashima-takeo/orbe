import Foundation
import OrbeEditorCore

/// 字下げの桁の計算（VS Code の `CursorColumns` と `normalizeIndentation`）。タブの幅は字下げの単位。
enum Indenting {
  /// 行頭から `column` までの見た目の桁（タブは次のタブ位置まで）。
  static func visibleColumn(_ units: some Collection<UInt16>, upTo column: Int, tabSize: Int) -> Int
  {
    var visible = 0
    for unit in units.prefix(column) {
      visible = unit == 0x09 ? visible + tabSize - visible % tabSize : visible + 1
    }
    return visible
  }

  /// 見た目の桁 `visible` にいちばん近い位置（VS Code の `columnFromVisibleColumn`）。
  static func column(_ units: some Collection<UInt16>, atVisible visible: Int, tabSize: Int) -> Int
  {
    guard visible > 0 else { return 0 }
    var before = 0
    for (index, unit) in units.enumerated() {
      let after = unit == 0x09 ? before + tabSize - before % tabSize : before + 1
      if after >= visible { return after - visible < visible - before ? index + 1 : index }
      before = after
    }
    return units.count
  }

  /// ⌫ が字下げの空白の中（最初の空白でない字まで）で消す先——前のタブ位置の位置。字下げの外や行頭なら nil。
  static func previousTabStop(in line: ContiguousArray<UInt16>, column: Int, size: Int) -> Int? {
    let indentEnd = line.firstIndex { $0 != 0x20 && $0 != 0x09 } ?? line.count
    guard column > 0, column <= indentEnd else { return nil }
    let from = visibleColumn(line, upTo: column, tabSize: size)
    let to = max(0, from - 1 - (from - 1) % size)
    return Self.column(line, atVisible: to, tabSize: size)
  }

  /// 字下げの空白を文書の作法に揃える（VS Code の `normalizeIndentation`）——見た目の桁を数え、タブの文書ならタブと端数の
  /// 空白、空白の文書なら空白で書き直す。
  static func normalize(_ whitespace: [UInt16], _ indentation: Indentation) -> String {
    let size = indentation.unit
    var columns = 0
    for unit in whitespace {
      columns = unit == 0x09 ? columns + size - columns % size : columns + 1
    }
    guard indentation.usesTabs else { return String(repeating: " ", count: columns) }
    return String(repeating: "\t", count: columns / size)
      + String(repeating: " ", count: columns % size)
  }

  /// 見た目の桁 `columns` ぶんの字下げ（文書の作法で）。
  static func indent(columns: Int, _ indentation: Indentation) -> String {
    indentation.usesTabs
      ? String(repeating: "\t", count: columns / indentation.unit)
      : String(repeating: " ", count: columns)
  }
}

/// Tab・⇧Tab・字下げの規則。
extension EditCommands {
  /// Tab（VS Code の `TabOperation`）——選択が無いか 1 行の中なら、選択を次のタブ位置までの空白（タブの文書ならタブ文字）に
  /// 置き換える。行をまたぐか行全体を選んでいれば字下げする。
  static func tab(_ state: EditState, _ env: EditingEnvironment) -> CommandResult {
    let text = env.text
    let wholeLines = state.cursors.all.contains { cursor in
      let selection = cursor.selection
      guard selection.length > 0 else { return false }
      let rows = text.rows(of: selection)
      let content = text.contentRange(ofRow: rows.lowerBound)
      return rows.lowerBound != rows.upperBound
        || (selection.location == content.location && NSMaxRange(selection) >= NSMaxRange(content))
    }
    guard !wholeLines else { return shift(outdent: false, state, env) }
    return edit(state, env, undo: .other) { cursor in
      let selection = cursor.selection
      guard !env.indentation.usesTabs else { return Replacement(selection, "\t") }
      let row = text.row(containing: selection.location)
      let start = text.lineStart(row)
      let size = env.indentation.unit
      let visible = Indenting.visibleColumn(
        text.units(in: NSRange(location: start, length: selection.location - start)),
        upTo: selection.location - start, tabSize: size)
      return Replacement(selection, String(repeating: " ", count: size - visible % size))
    }
  }

  /// 字下げ・字下げを戻す（VS Code の `ShiftCommand`、`useTabStops`）——選択の行（終わりが行頭なら、その行は含めない）の
  /// 行頭の空白を、次（前）の字下げの位置までの空白に書き直す。字下げでは空行を飛ばし（1 行だけなら空行も）、戻すでは空白の
  /// 無い行を飛ばす。選択は書き直した行に付いていき、始まりが字下げの中なら始まりは動かない。
  static func shift(outdent: Bool, _ state: EditState, _ env: EditingEnvironment) -> CommandResult {
    let text = env.text
    var edits: [TextEdit] = []
    for cursor in state.cursors.all {
      edits += shiftEdits(cursor.selection, outdent: outdent, text, env.indentation)
    }
    edits.sort { $0.range.location < $1.range.location }
    var unique: [TextEdit] = []
    for edit in edits where unique.last?.range.location != edit.range.location {
      unique.append(edit)
    }
    let batch = EditBatch(unique)
    guard !batch.isEmpty else { return CommandResult(state: state) }
    var cursors = state.cursors.map { cursor in
      let selection = cursor.selection
      let row = text.row(containing: selection.location)
      let lineStart = text.lineStart(row)
      guard selection.length > 0 else {
        let blank = Self.firstNonWhitespace(ofRow: row, text) == nil
        let at = blank ? NSMaxRange(text.contentRange(ofRow: row)) : selection.location
        return Cursor(batch.map(at))
      }
      let inIndent = selection.location <= (Self.firstNonWhitespace(ofRow: row, text) ?? .max)
      let kept = batch.map(lineStart) + selection.location - lineStart
      let start =
        inIndent ? min(batch.map(selection.location), kept) : batch.map(selection.location)
      let end = batch.map(NSMaxRange(selection))
      return Cursor.selecting(
        NSRange(location: start, length: max(0, end - start)), reversed: cursor.isReversed)
    }
    cursors.normalize()
    return CommandResult(
      state: EditState(cursors: cursors, mark: state.mark.map(batch.map)), edits: batch,
      undo: .other)
  }

  private static func shiftEdits(
    _ selection: NSRange, outdent: Bool, _ text: TextRope, _ indentation: Indentation
  ) -> [TextEdit] {
    var rows = text.rows(of: selection)
    if selection.length > 0, rows.lowerBound < rows.upperBound,
      NSMaxRange(selection) == text.lineStart(rows.upperBound)
    {
      rows = rows.lowerBound...(rows.upperBound - 1)
    }
    let single = rows.lowerBound == rows.upperBound
    let size = indentation.unit
    return rows.compactMap { row in
      let content = text.contentRange(ofRow: row)
      let units = text.units(in: content)
      let indentEnd = units.firstIndex { $0 != 0x20 && $0 != 0x09 } ?? units.count
      if outdent, units.isEmpty || indentEnd == 0 { return nil }
      if !outdent, !single, units.isEmpty { return nil }
      let visible = Indenting.visibleColumn(units, upTo: indentEnd, tabSize: size)
      let target =
        outdent ? max(0, visible - 1 - (visible - 1) % size) : visible + size - visible % size
      return TextEdit(
        range: NSRange(location: content.location, length: indentEnd),
        replacement: Indenting.indent(columns: target, indentation))
    }
  }
}
