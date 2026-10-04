import Foundation
import OrbeEditorCore

/// 字下げの桁の計算（VS Code の `CursorColumns` と `normalizeIndentation`）。見た目の桁は書記素ごとに進み、タブは次の
/// タブ位置まで、全角と絵文字は 2 桁（VS Code と同じ等幅の数え方）。タブの幅は字下げの単位。
enum Indenting {
  /// 行頭から `column` までの見た目の桁。
  static func visibleColumn(_ units: some Collection<UInt16>, upTo column: Int, tabSize: Int)
    -> Int
  {
    var visible = 0
    for (_, codePoint) in graphemes(units.prefix(column)) {
      visible = next(visible, codePoint, tabSize)
    }
    return visible
  }

  /// 見た目の桁 `visible` にいちばん近い位置（VS Code の `columnFromVisibleColumn`）。
  static func column(_ units: some Collection<UInt16>, atVisible visible: Int, tabSize: Int)
    -> Int
  {
    guard visible > 0 else { return 0 }
    var before = 0
    var offset = 0
    for (length, codePoint) in graphemes(units) {
      let after = next(before, codePoint, tabSize)
      if after >= visible { return after - visible < visible - before ? offset + length : offset }
      before = after
      offset += length
    }
    return units.count
  }

  /// 書記素ごとの単位の数と最初の符号位置。
  private static func graphemes(_ units: some Collection<UInt16>) -> [(
    length: Int, codePoint: UInt32
  )] {
    String(decoding: units, as: UTF16.self).map {
      ($0.utf16.count, $0.unicodeScalars.first?.value ?? 0)
    }
  }

  private static func next(_ visible: Int, _ codePoint: UInt32, _ tabSize: Int) -> Int {
    codePoint == 0x09
      ? visible + tabSize - visible % tabSize : visible + CharacterWidth.columns(codePoint)
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
  /// Tab（VS Code の `TabOperation`）——カーソルごとに、行をまたぐか行全体を選んでいれば、その行を字下げする。そうでなければ
  /// （選択が無いか 1 行の中の一部なら）、選択を次のタブ位置までの空白（タブの文書ならタブ文字）に置き換える。
  static func tab(_ state: EditState, _ env: EditingEnvironment) -> CommandResult {
    let jumps = state.cursors.all.map { cursor in
      indentsLines(cursor.selection, env.text) ? nil : jump(at: cursor.selection, env)
    }
    guard jumps.contains(nil) else {
      return edit(state, env, undo: .other) {
        Replacement($0.selection, jump(at: $0.selection, env))
      }
    }
    return shift(outdent: false, state, env, jumps: jumps)
  }

  /// Tab が選択の行を字下げするか——選択が行をまたぐか、行全体を選んでいる。
  private static func indentsLines(_ selection: NSRange, _ text: TextRope) -> Bool {
    guard selection.length > 0 else { return false }
    let rows = text.rows(of: selection)
    let content = text.contentRange(ofRow: rows.lowerBound)
    return rows.lowerBound != rows.upperBound
      || (selection.location == content.location && NSMaxRange(selection) >= NSMaxRange(content))
  }

  /// 選択を置き換える、次のタブ位置までの空白（タブの文書ならタブ文字）。
  private static func jump(at selection: NSRange, _ env: EditingEnvironment) -> String {
    guard !env.indentation.usesTabs else { return "\t" }
    let text = env.text
    let start = text.lineStart(text.row(containing: selection.location))
    let size = env.indentation.unit
    let visible = Indenting.visibleColumn(
      text.units(in: NSRange(location: start, length: selection.location - start)),
      upTo: selection.location - start, tabSize: size)
    return String(repeating: " ", count: size - visible % size)
  }

  /// 字下げ・字下げを戻す（VS Code の `ShiftCommand`、`useTabStops`）——選択の行（終わりが行頭なら、その行は含めない）の
  /// 行頭の空白を、次（前）の字下げの位置までの空白に書き直す。字下げでは空行を飛ばし（1 行だけなら空行も）、戻すでは空白の
  /// 無い行を飛ばす。選択は書き直した行に付いていき、始まりが字下げの中なら始まりは動かない。`jumps` の i 番目があれば、
  /// i 番目のカーソルは行を書き直さず、選択をその文字列に置き換えてキャレットを末尾に置く（Tab の行の中のカーソル。書き直す
  /// 行の空白に重なれば置き換えない）。
  static func shift(
    outdent: Bool, _ state: EditState, _ env: EditingEnvironment, jumps: [String?] = []
  ) -> CommandResult {
    let text = env.text
    let all = state.cursors.all
    let (batch, jumped) = shiftBatch(all, outdent: outdent, jumps: jumps, env)
    guard !batch.isEmpty else { return CommandResult(state: state) }
    let points = all.map { cursor in
      let selection = cursor.selection
      let row = text.row(containing: selection.location)
      guard selection.length > 0 else {
        let blank = Self.firstNonWhitespace(ofRow: row, text) == nil
        let at = blank ? NSMaxRange(text.contentRange(ofRow: row)) : selection.location
        return [at, at, at]
      }
      return [text.lineStart(row), selection.location, NSMaxRange(selection)]
    }
    let mapped = batch.map(points.flatMap { $0 })
    var shifted: [Cursor] = []
    shifted.reserveCapacity(all.count)
    for (index, cursor) in all.enumerated() {
      if let end = jumped[index] {
        shifted.append(Cursor(end))
        continue
      }
      let selection = cursor.selection
      let (lineStart, start, end) = (
        mapped[3 * index], mapped[3 * index + 1], mapped[3 * index + 2]
      )
      guard selection.length > 0 else {
        shifted.append(Cursor(start))
        continue
      }
      let row = text.row(containing: selection.location)
      let inIndent = selection.location <= (Self.firstNonWhitespace(ofRow: row, text) ?? .max)
      let kept = lineStart + selection.location - points[index][0]
      let from = inIndent ? min(start, kept) : start
      shifted.append(
        Cursor.selecting(
          NSRange(location: from, length: max(0, end - from)), reversed: cursor.isReversed))
    }
    var cursors = CursorList(shifted[0], others: Array(shifted.dropFirst()))
    cursors.normalize()
    return CommandResult(
      state: EditState(cursors: cursors, mark: state.mark.map(batch.map)), edits: batch,
      undo: .other)
  }

  /// 字下げの束と、選択を置き換えたカーソルの番号 → 置き換えた後のキャレット。同じ行の書き直しは 1 回で、書き直す行の空白に
  /// 重なる（同じ位置から始まるものを含む）置き換えは捨てる。
  private static func shiftBatch(
    _ cursors: [Cursor], outdent: Bool, jumps: [String?], _ env: EditingEnvironment
  ) -> (EditBatch, jumped: [Int: Int]) {
    var edits: [(edit: TextEdit, jumping: Int?)] = []
    for (index, cursor) in cursors.enumerated() {
      if index < jumps.count, let string = jumps[index] {
        edits.append((TextEdit(range: cursor.selection, replacement: string), index))
      } else {
        edits += shiftEdits(cursor.selection, outdent: outdent, env.text, env.indentation).map {
          ($0, nil)
        }
      }
    }
    edits.sort {
      ($0.edit.range.location, $0.jumping ?? -1) < ($1.edit.range.location, $1.jumping ?? -1)
    }
    var unique: [(edit: TextEdit, jumping: Int?)] = []
    for item in edits {
      if let last = unique.last?.edit.range,
        item.edit.range.location == last.location
          || item.edit.range.location < NSMaxRange(last)
      {
        continue
      }
      unique.append(item)
    }
    let batch = EditBatch(unique.map(\.edit))
    var jumped: [Int: Int] = [:]
    for (item, range) in zip(unique, batch.newRanges) {
      if let index = item.jumping { jumped[index] = NSMaxRange(range) }
    }
    return (batch, jumped)
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
