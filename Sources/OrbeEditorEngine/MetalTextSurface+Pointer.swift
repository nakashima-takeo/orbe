import AppKit
import OrbeEditorCore

/// 面の上の場所——行番号の数字の列・git の印の列・本文（最終行より下の空き地を含む）・俯瞰（ミニマップと縦横の
/// スクロールバー）。
enum PointerArea {
  case numbers, marks, text, overview
}

/// view の点を本文の言葉にしたもの。
struct PointerHit {
  var area: PointerArea
  var row: Int
  /// いちばん近い書記素の境（最終行より下なら本文の終わり）。
  var offset: Int
}

extension MetalTextSurface {
  /// view の点（flipped、pt）の場所。行は縦の並び（`RowLayout`）で引き、推定が無い——遠くへ飛んだ直後でも、ポインタの下の
  /// 行・字に当たる。差し込んだ行と区画の上は次の文書の行の行頭（最終行の後の塊の上は本文の終わり）に当たる。`position` は
  /// スクロールの位置（省けば今の位置）。
  func hit(_ point: CGPoint, position: SIMD2<Double>? = nil) -> PointerHit? {
    guard let env = bodySite.editingEnvironment() else { return nil }
    let text = env.text
    let p = position ?? scrollPosition
    let column = config.columnWidth(lineCount: text.lineCount)
    let area: PointerArea =
      textView.overview.area(at: point) != nil
      ? .overview
      : point.x < column - config.marks.gutterWidth ? .numbers : point.x < column ? .marks : .text
    let y = Double(point.y - config.topInset) + p.y
    let item = rows.item(atY: y)
    if case .block(let index) = item {
      let line = rows.boundaries[index]
      guard line < text.lineCount else {
        return PointerHit(area: area, row: text.lineCount - 1, offset: text.length)
      }
      return PointerHit(area: area, row: line, offset: text.lineStart(line))
    }
    guard case .line(let line) = item, line < text.lineCount else {
      return PointerHit(area: area, row: text.lineCount - 1, offset: text.length)
    }
    let row = max(0, line)
    let x = CGFloat(Double(point.x - column) + p.x)
    return PointerHit(
      area: area, row: row, offset: text.lineStart(row) + env.geometry.column(atX: x, row: row))
  }

  /// 点を含む書記素。点が文書の行の字の上でなければ（行番号の列・行末より右・字の無い行・差し込んだ行と区画・最終行より
  /// 下の空き地）nil。当たりと同じ組版の行から引くので、右から左の字の並びでも見た目の字に当たる。`position` はスクロールの
  /// 位置（省けば今の位置）。
  func character(at point: CGPoint, position: SIMD2<Double>? = nil) -> NSRange? {
    guard let text = currentContent?.text else { return nil }
    let p = position ?? scrollPosition
    let column = config.columnWidth(lineCount: text.lineCount)
    let y = Double(point.y - config.topInset) + p.y
    guard point.x >= column, point.y >= config.topInset,
      case .line(let row) = rows.item(atY: y), (0..<text.lineCount).contains(row)
    else { return nil }
    let x = CGFloat(Double(point.x - column) + p.x)
    let (source, start) = LineShaper.source(row: row, in: text)
    let stops = lineStops.stops(source, tabWidth: config.tabWidth(columns: indentation.unit))
    guard x < stops.width, let glyph = stops.glyph(atX: x) else { return nil }
    return text.grapheme(containing: start + stops.offsets[glyph])
  }

  /// 点の下の字が URL の中なら、その URL。
  func link(at point: CGPoint) -> URL? {
    guard let text = currentContent?.text, let character = character(at: point) else { return nil }
    let row = text.row(containing: character.location)
    let start = text.lineStart(row)
    let length = min(NSMaxRange(text.contentRange(ofRow: row)) - start, LineShaper.limit)
    let line = text.substring(NSRange(location: start, length: length))
    return LinkDetector.links(in: line).first {
      NSLocationInRange(character.location - start, $0.range)
    }?.url
  }
}
