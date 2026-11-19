import AppKit
import CoreText

/// 選べる文を幅で組んだもの（`ZoneTextLayout.typeset(_:width:)`）——見え方つきの文と、組んだ行の列と、行ごとの字の
/// 高さと、文の rope。載せる側は行の範囲・幅・地の x 範囲で飾りを置き、面は組んだ行をそのまま描き・当たりと選択に使う
/// （面は選べる文を組まない）。
///
/// 組み終えた後は変わらない。組んだスレッドから別のスレッドへ渡せる（載せる側が裏で組み、main へ渡す）——字体は不変で、
/// Core Text は字体のオブジェクトを複数のスレッドから同時に使えると保証する。組んだ行（CTLine）は同時に複数のスレッドで
/// 使わない約束で、渡した後は渡した先だけが使う。
public final class ZoneTypeset: @unchecked Sendable {
  /// 行の字の高さ——行の始まりの字の見え方の字体（文の終わりの位置なら最後の見え方の字体）の上下の高さ。
  public struct Metrics: Sendable, Equatable {
    public let ascent: CGFloat
    public let descent: CGFloat
  }

  public let content: ZoneStyledText
  /// 組んだ行（文の先頭から順に）。
  public let lines: [ZoneTextLayout.TypesetLine]
  /// 行ごとの字の高さ（`lines` と同じ順）。
  public let metrics: [Metrics]
  public let rope: TextRope

  init(_ content: ZoneStyledText, lines: [ZoneTextLayout.TypesetLine]) {
    self.content = content
    self.lines = lines
    var end = 0
    let styles = content.styles
    let ends = styles.map { style -> Int in
      end += style.length
      return end
    }
    metrics = lines.map { line in
      var (index, upper) = (0, ends.count)
      while index < upper {
        let middle = (index + upper) / 2
        if line.range.location < ends[middle] { upper = middle } else { index = middle + 1 }
      }
      let font =
        styles.indices.contains(index)
        ? styles[index].font : (styles.last?.font ?? NSFont.systemFont(ofSize: 12) as CTFont)
      return Metrics(ascent: CTFontGetAscent(font), descent: CTFontGetDescent(font))
    }
    rope = TextRope(content.string)
  }
}
