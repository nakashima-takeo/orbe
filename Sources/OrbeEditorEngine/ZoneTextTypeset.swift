import AppKit
import CoreText
import OrbeEditorCore

/// 字の行を組んだものを使い回す鍵——連なりごとの字（UTF-16 の並び）と字体。色は含めない。
struct ZoneLabelKey: Hashable {
  let units: [[UInt16]]
  let fonts: [CTFont]

  init(_ runs: [ZoneTextRun]) {
    units = runs.map { Array($0.string.utf16) }
    fonts = runs.map { $0.font as CTFont }
  }
}

/// 選べる文のまとまりを組んだもの——文と見え方と行の範囲（覚えの鍵）と、そこから決まるもの（組んだ行・行ごとの
/// 外観に依らない形のグリフの連なり・行の字体の高さ・文）。面は当たりの表と一緒に持ち、次の描き直しで鍵が同じなら
/// 組み直さない（ホバーの描き直しで段落を組まない）。色は鍵に入れない（組み方を変えないので、写すときに
/// 今の外観で解く）。覚えは当たりの表と同じく、絵の差し込みが外れれば消え、描き直した絵に無いまとまりの分は次の表に
/// 移らない。
struct ZoneTextTypeset {
  /// 外観に依らない形のグリフの連なり（フォントは面の中で揃えたもの。縦の位置は、どれかのグリフが基線から外れるときだけ）。
  struct Run {
    let style: Int
    let font: CTFont
    let glyphs: [CGGlyph]
    let positions: [CGPoint]
    let ys: [Float]
  }

  let content: ZoneStyledText
  let ranges: [NSRange]
  let lines: [ZoneTextLayout.TypesetLine]
  let runs: [[Run]]
  /// 行ごとの、行の始まりの字の見え方の字体（文の終わりの位置なら最後の見え方の字体）の上下の高さ。
  let metrics: [(ascent: CGFloat, descent: CGFloat)]
  let rope: TextRope

  init(_ text: ZoneText, prepare: ([ZoneTextLayout.GlyphRun]) -> [Run]) {
    content = text.content
    ranges = text.lines.map(\.range)
    lines = ZoneTextLayout.lines(of: text)
    runs = lines.map { prepare($0.runs) }
    var end = 0
    let styles = text.content.styles
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
      return (CTFontGetAscent(font), CTFontGetDescent(font))
    }
    rope = TextRope(text.content.string)
  }

  /// `text` を同じに組めるか——色を除く見え方つきの文と、行の範囲が同じ。
  func matches(_ text: ZoneText) -> Bool {
    guard ranges == text.lines.map(\.range), content.styles.count == text.content.styles.count,
      content.string.utf16.elementsEqual(text.content.string.utf16)
    else { return false }
    return zip(content.styles, text.content.styles).allSatisfy {
      var style = $0
      style.color = $1.color
      return style == $1
    }
  }
}
