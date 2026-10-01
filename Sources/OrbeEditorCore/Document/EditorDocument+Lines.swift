import Foundation

/// 文書の写しの行から答える、俯瞰と検索のための問い合わせ。
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

  /// 面の行番号の列が問う行の数・オフセットの行・行の区間（`TextSurfaceDelegate`）。
  public func surfaceLineCount(_ surface: any TextSurface) -> Int {
    text.lineCount
  }

  public func surface(_ surface: any TextSurface, lineContaining offset: Int) -> Int {
    text.row(containing: offset)
  }

  public func surface(_ surface: any TextSurface, rangeOfLine line: Int) -> NSRange {
    let start = text.lineStart(line)
    return NSRange(location: start, length: text.lineEnd(line) - start)
  }
}
