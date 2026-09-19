import Foundation

/// 俯瞰の幾何——行の言葉（行数・先頭に見えている行・可視行数）だけから、ミニマップの窓・表示範囲の帯・
/// 行 ↔ y・クリック → 行を解く。面の pt と行高は入らない。
///
/// 文書のミニマップ高（行数 × ピッチ）が列に収まらなければ、窓はスクロール比率で比例スライドする——先頭で帯は
/// 上端、末尾で帯は下端に来る。帯は先頭行の隠れ割合まで含めて連続で追従する（行単位の跳びが無い）。
public struct OverviewGeometry: Equatable, Sendable {
  public let lineCount: Int
  /// 先頭に見えている行（小数。行 + 隠れ割合）。
  public let firstLine: CGFloat
  /// 可視行数（小数）。
  public let visibleLines: CGFloat
  /// 行 1 つが占める縦のピッチ。
  public let pitch: CGFloat
  /// 列の内側の高さ（余白を除く）。
  public let height: CGFloat

  public init(
    lineCount: Int, firstLine: CGFloat, visibleLines: CGFloat, pitch: CGFloat, height: CGFloat
  ) {
    self.lineCount = max(0, lineCount)
    self.firstLine = firstLine
    self.visibleLines = visibleLines
    self.pitch = pitch
    self.height = height
  }

  /// 文書全体のミニマップ高。
  public var documentHeight: CGFloat { CGFloat(lineCount) * pitch }

  /// 窓の先頭の y（文書のミニマップの座標）。収まるなら 0。
  public var windowOffset: CGFloat {
    let overflow = documentHeight - height
    guard overflow > 0 else { return 0 }
    let range = CGFloat(lineCount) - visibleLines
    guard range > 0 else { return 0 }
    return min(max(firstLine / range, 0), 1) * overflow
  }

  /// 行 n（0 始まり）の上端の y（列の座標）。
  public func y(ofLine line: Int) -> CGFloat { CGFloat(line) * pitch - windowOffset }

  /// 表示範囲の帯（列の座標。列と文書の終わりに収める——可視行数より短い文書で最後の行の下へ伸びない）。
  public var band: (y: CGFloat, height: CGFloat) {
    let top = firstLine * pitch - windowOffset
    let bottom = min(top + visibleLines * pitch, height, documentHeight - windowOffset)
    let y = max(0, top)
    return (y, max(0, bottom - y))
  }

  /// 窓に入る行（0 始まり。列の外にはみ出す端の行も含む）。
  public var windowLines: Range<Int> {
    guard lineCount > 0, pitch > 0 else { return 0..<0 }
    let first = max(0, Int(floor(windowOffset / pitch)))
    let last = min(lineCount, Int(ceil((windowOffset + height) / pitch)))
    return first..<max(first, last)
  }

  /// 列の y の下の行（0 始まり。列の外は端の行）。
  public func line(atY y: CGFloat) -> Int {
    guard lineCount > 0, pitch > 0 else { return 0 }
    return min(max(0, Int(floor((y + windowOffset) / pitch))), lineCount - 1)
  }

  /// 文書比例の写し（印の列）。行の区間 `lines`（0 始まり）を高さ `height` の列へ写す。高さは最小 `minimum`。
  public static func proportional(
    lines: Range<Int>, of lineCount: Int, height: CGFloat, minimum: CGFloat
  ) -> (y: CGFloat, height: CGFloat) {
    guard lineCount > 0 else { return (0, 0) }
    let scale = height / CGFloat(lineCount)
    let y = CGFloat(lines.lowerBound) * scale
    let h = max(minimum, CGFloat(lines.count) * scale)
    return (min(y, max(0, height - h)), h)
  }
}
