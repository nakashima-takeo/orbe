import Foundation
import OrbeEditorCore

/// 写すもの——平文と、行ごと写したか、色付きで書き出せる範囲（写したものが本文の 1 つの範囲のとき）、写した断片（選択を
/// 2 つ以上写したときの、文書の順の選択ごとの文字列）。
struct ClipboardCopy: Equatable {
  var text: String
  var entireLine: Bool
  var range: NSRange?
  var pieces: [String]?
}

/// 何を写し、どう貼るか（VS Code の既定。`emptySelectionClipboard`）。純関数。
enum ClipboardText {
  /// 写すもの。選択があれば選択（カーソルが複数なら文書の改行でつなぐ）、選択が空ならキャレットの行を改行込みで（改行の
  /// 無い最終行は文書の改行を足す）。行ごと写した印は、カーソルが 1 つで選択が空のときだけ。
  static func copy(_ cursors: CursorList, _ text: TextRope, lineBreak: LineBreak) -> ClipboardCopy {
    let all = cursors.all.sorted { $0.selection.location < $1.selection.location }
    let empty = all.allSatisfy { $0.selection.length == 0 }
    var rows = Set<Int>()
    var pieces: [String] = []
    var ranges: [NSRange] = []
    for cursor in all {
      guard empty else {
        guard cursor.selection.length > 0 else { continue }
        pieces.append(text.substring(cursor.selection))
        ranges.append(cursor.selection)
        continue
      }
      let row = text.row(containing: cursor.position)
      guard rows.insert(row).inserted else { continue }
      let range = NSRange(
        location: text.lineStart(row), length: text.lineEnd(row) - text.lineStart(row))
      let line = text.substring(range)
      pieces.append(row == text.lineCount - 1 ? line + lineBreak.string : line)
      ranges.append(range)
    }
    return ClipboardCopy(
      text: pieces.joined(separator: empty ? "" : lineBreak.string),
      entireLine: empty && all.count == 1, range: ranges.count == 1 ? ranges[0] : nil,
      pieces: !empty && pieces.count > 1 ? pieces : nil)
  }

  /// 貼る文字列をカーソルへ配るなら、文書の順のカーソルごとの文字列（VS Code の `_distributePasteToCursors`、
  /// `multiCursorPaste: spread`）。カーソルが 1 本なら配らない。写した断片の数がカーソルの数と同じなら断片を配る。行ごと
  /// 写した印があれば配らない。末尾の改行 1 つ（`\n` と、その前の `\r`）を除いて行に割った数がカーソルの数と同じなら、
  /// 1 行ずつ配る（Orbe の外から写した文字列でも）。
  static func distribution(
    _ string: String, pieces: [String]?, entireLine: Bool, cursors count: Int
  ) -> [String]? {
    guard count > 1 else { return nil }
    if let pieces, pieces.count == count { return pieces }
    guard !entireLine else { return nil }
    var units = Array(string.utf16)
    if units.last == 0x0A { units.removeLast() }
    if units.last == 0x0D { units.removeLast() }
    var lines: [String] = []
    var start = 0
    var index = 0
    while index < units.count {
      let unit = units[index]
      guard unit == 0x0A || unit == 0x0D else {
        index += 1
        continue
      }
      lines.append(String(decoding: units[start..<index], as: UTF16.self))
      index += unit == 0x0D && index + 1 < units.count && units[index + 1] == 0x0A ? 2 : 1
      start = index
    }
    lines.append(String(decoding: units[start...], as: UTF16.self))
    return lines.count == count ? lines : nil
  }

  /// 選択が空の切り取りで消す範囲（VS Code の `DeleteOperations.cut`）——行を次の行頭まで。最終行なら前の行の改行から、
  /// 行が 1 つなら行の中身だけ。
  static func cutRange(_ cursor: Cursor, _ text: TextRope) -> NSRange {
    guard cursor.selection.length == 0 else { return cursor.selection }
    let row = text.row(containing: cursor.position)
    let start = text.lineStart(row)
    if row + 1 < text.lineCount {
      return NSRange(location: start, length: text.lineStart(row + 1) - start)
    }
    guard row > 0 else { return NSRange(location: start, length: text.length - start) }
    let from = NSMaxRange(text.contentRange(ofRow: row - 1))
    return NSRange(location: from, length: text.length - from)
  }

  /// 行ごと写した文字列を、キャレットの行の上に行として入れるか——印があり、どの選択も空で、文字列の改行が末尾の 1 つだけ。
  static func pastesAboveLine(
    _ units: ContiguousArray<UInt16>, entireLine: Bool, _ cursors: CursorList
  )
    -> Bool
  {
    entireLine && cursors.all.allSatisfy { $0.selection.length == 0 }
      && units.firstIndex(of: 0x0A) == units.count - 1
  }
}
