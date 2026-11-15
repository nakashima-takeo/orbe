import Foundation

/// 文書の写しの行から答える問い合わせ——検索と出現に使う語の範囲と、編集が始まりの行の中身を変えないか。
extension EditorDocument {
  /// 選択の先頭の位置の語（出現の強調・⌘F の種）。長い行はキャレットの前後の窓だけを読む（→ `Occurrences.wordWindow`）。
  public func word(at selection: NSRange) -> NSRange? {
    let row = text.row(containing: selection.location)
    let start = text.lineStart(row)
    var end = text.lineEnd(row)
    let tailStart = max(start, end - 2)
    for unit in text.units(in: NSRange(location: tailStart, length: end - tailStart)).reversed() {
      guard unit == 0x0A || unit == 0x0D else { break }
      end -= 1
    }
    let window = Occurrences.wordWindow(
      caret: selection.location, line: NSRange(location: start, length: end - start))
    return Occurrences.word(
      at: selection, text: text.substring(window), textStart: window.location)
  }

  /// 編集の前の本文で、行の数を変える編集の始まりの行が中身を変えないか——始まりの行の、位置から改行までの残り（LF なら
  /// 空、CRLF なら `\r`）について、差し込む字が「残り + 改行」で始まるか、差し込む字が空で終わりの位置の残りも同じ
  /// （行をつなぐ削除）。改行を差し込まず行もつながない編集は行を読まない（打鍵の手間を増やさない）。
  func keepsStartRow(_ edit: TextEdit, start: TextPoint, oldEnd: TextPoint) -> Bool {
    let replacement = edit.replacement
    if replacement.isEmpty {
      guard oldEnd.row > start.row else { return false }
      let rest = remainder(after: edit.range.location, row: start.row)
      let end = remainder(after: NSMaxRange(edit.range), row: oldEnd.row)
      return rest.length == end.length && text.units(in: rest) == text.units(in: end)
    }
    guard replacement.contains(0x0A) else { return false }
    let rest = remainder(after: edit.range.location, row: start.row)
    guard replacement.count > rest.length, replacement[rest.length] == 0x0A else { return false }
    return text.units(in: rest).elementsEqual(replacement.prefix(rest.length))
  }

  /// 行 `row` の中の位置 `location` から、その行の改行の前（最終行なら本文の終わり）までの区間。
  private func remainder(after location: Int, row: Int) -> NSRange {
    let end = row + 1 < text.lineCount ? text.lineStart(row + 1) - 1 : text.length
    return NSRange(location: location, length: end - location)
  }
}
