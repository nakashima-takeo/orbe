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

  /// 先頭に見えている行（小数。行 + 隠れ割合）と可視行数（小数）——俯瞰の式の入力。
  public var viewportLines: (first: CGFloat, visible: CGFloat) {
    let viewport = surface.viewport
    let row = CGFloat(text.row(containing: viewport.firstVisible))
    return (row + viewport.hiddenFraction, viewport.visibleLines)
  }

  /// 先頭行（小数）の位置へスクロールする（`viewport` の逆。行は行の数に収める）。
  public func scroll(toFirstLine line: CGFloat) {
    let clamped = min(max(0, line), CGFloat(text.lineCount - 1))
    let row = Int(floor(clamped))
    surface.scroll(toTop: text.lineStart(row), hiddenFraction: clamped - CGFloat(row))
  }
}
