import Foundation
import OrbeEditorCore

/// 写すもの——平文と、行ごと写したか、色付きで書き出せる範囲（写したものが本文の 1 つの範囲のとき）。
struct ClipboardCopy: Equatable {
  var text: String
  var entireLine: Bool
  var range: NSRange?
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
      entireLine: empty && all.count == 1, range: ranges.count == 1 ? ranges[0] : nil)
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
