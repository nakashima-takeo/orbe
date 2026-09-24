import Foundation

/// ミニマップの配置——どの行から描くか・帯の位置と高さ・帯のドラッグと押下の写像。VS Code `MinimapLayout.create`
/// （size = proportional、scrollBeyondLastLine あり、上下の余白 0）を行の単位へ移したもの。VS Code の px の式に
/// `scrollTop = 先頭行 × 行高`・`scrollHeight = (行数 + max(0, 表示行数 − 1)) × 行高` を代入すると行高が約分で消え、
/// 残る pt は列の高さとミニマップの行高だけになる。行は 0 始まり。
public struct MinimapLayout: Equatable, Sendable {
  /// ミニマップの 1 行の高さ（pt。1x でも 2x でも 2pt）。
  public static let lineHeight: CGFloat = 2

  public let lineCount: Int
  /// 先頭に見えている行（小数。行 + 隠れ割合）。
  public let firstLine: CGFloat
  /// スクロール全体の行数（最終行を最上段まで送れるぶんを含む）。前回の配置との比較に使う。
  public let scrollLines: CGFloat
  /// 帯を出すか（文書が 1 画面に収まらない）。
  public let sliderNeeded: Bool
  /// 帯の上端と高さ（列の座標）。
  public let sliderTop: CGFloat
  public let sliderHeight: CGFloat
  /// 帯の 1pt の動きに対する先頭行の動き（行 / pt）。0 ならドラッグしても動かない。
  public let linesPerSliderPoint: CGFloat
  /// 描く行（0 始まり）。`startLine` が列の上端に来る。
  public let lines: Range<Int>

  public var startLine: Int { lines.lowerBound }

  /// `previous` は直前の配置（上下のスクロールで描き始めの行が行き来して揺れないようにする）。
  public init(
    lineCount: Int, firstLine: CGFloat, visibleLines: CGFloat, height: CGFloat,
    previous: MinimapLayout? = nil
  ) {
    let count = max(1, lineCount)
    let m = Self.lineHeight
    let lines = CGFloat(count)
    let fitting = Int(floor(max(0, height) / m))
    let sliderHeight = floor(visibleLines * m)
    let extraBottom = max(0, visibleLines - 1)
    let scrollLines = lines + extraBottom
    var maxSliderTop =
      extraBottom > 0
      ? (lines + extraBottom - visibleLines - 1) * m : max(0, lines * m - sliderHeight)
    maxSliderTop = min(height - sliderHeight, maxSliderTop)
    let scrollable = scrollLines - visibleLines
    let ratio = scrollable > 0 && maxSliderTop > 0 ? maxSliderTop / scrollable : 0
    self.lineCount = count
    self.firstLine = firstLine
    self.scrollLines = scrollLines
    self.sliderHeight = sliderHeight
    linesPerSliderPoint = ratio > 0 ? 1 / ratio : 0
    if CGFloat(fitting) >= scrollLines {
      sliderNeeded = maxSliderTop > 0
      sliderTop = firstLine * ratio
      self.lines = 0..<count
      return
    }
    let viewportStart = floor(firstLine)
    var start = max(0, Int(floor(viewportStart - firstLine * ratio / m)))
    if let previous, previous.scrollLines == scrollLines {
      if previous.firstLine > firstLine { start = min(start, previous.startLine) }
      if previous.firstLine < firstLine { start = max(start, previous.startLine) }
    }
    let end = min(count, start + fitting)
    sliderNeeded = true
    sliderTop = (firstLine - CGFloat(start)) * m
    self.lines = start..<max(start, end)
  }

  /// ミニマップの幅（pt）。VS Code `EditorLayoutInfoComputer` の式（1 字 1pt）——`remaining` は本体の幅からガターを
  /// 除いたもの、`charWidth` は本文の半角の送り幅、`scrollbar` は右端のスクロールバーの幅。本文の桁とミニマップの桁が
  /// 釣り合う幅に、字の左のガター 8 を足し、`maxWidth` で止める。
  public static func width(
    remaining: CGFloat, charWidth: CGFloat, scrollbar: CGFloat, maxWidth: CGFloat
  ) -> CGFloat {
    min(maxWidth, max(0, floor((remaining - scrollbar - 2) / (charWidth + 1))) + 8)
  }

  /// 行の上端の y（列の座標）。
  public func y(ofLine line: Int) -> CGFloat { CGFloat(line - startLine) * Self.lineHeight }

  /// 帯の上端の範囲か。
  public func sliderContains(y: CGFloat) -> Bool {
    sliderNeeded && y >= sliderTop && y < sliderTop + sliderHeight
  }

  /// 帯を `delta` pt 動かしたときの先頭行（この配置を起点にする——ドラッグの間は押した時点の配置を使い続ける）。
  public func firstLine(afterDragging delta: CGFloat) -> CGFloat {
    firstLine + delta * linesPerSliderPoint
  }

  /// 列の y の下の行（帯の外の押下で中央へ移す行）。
  public func line(atY y: CGFloat) -> Int {
    min(lineCount - 1, max(0, Int(floor(y / Self.lineHeight)) + startLine))
  }
}
