import SwiftUI

/// 内蔵ブラウザのツールバー用手作りグリフ（`EditorGlyphs` と同じ viewBox 比例方式）。
enum BrowserGlyphs {
  struct Part {
    let path: Path
    let fills: Bool
    let opacity: Double
  }

  struct Glyph {
    let viewBox: CGFloat
    let stroke: CGFloat
    let parts: (CGFloat) -> [Part]
  }

  /// 戻る `M10 3.5L5.5 8l4.5 4.5`（stroke 1.5）。
  static let back = Glyph(viewBox: 16, stroke: 1.5) { k in
    var path = Path()
    path.move(to: CGPoint(x: 10 * k, y: 3.5 * k))
    path.addLine(to: CGPoint(x: 5.5 * k, y: 8 * k))
    path.addLine(to: CGPoint(x: 10 * k, y: 12.5 * k))
    return [Part(path: path, fills: false, opacity: 1)]
  }

  /// 進む `M6 3.5L10.5 8L6 12.5`（stroke 1.5）。
  static let forward = Glyph(viewBox: 16, stroke: 1.5) { k in
    var path = Path()
    path.move(to: CGPoint(x: 6 * k, y: 3.5 * k))
    path.addLine(to: CGPoint(x: 10.5 * k, y: 8 * k))
    path.addLine(to: CGPoint(x: 6 * k, y: 12.5 * k))
    return [Part(path: path, fills: false, opacity: 1)]
  }

  /// 再読込 `M13 8a5 5 0 1 1-1.7-3.75` `M13 2.8v2.4h-2.4`（stroke 1.5）。
  static let reload = Glyph(viewBox: 16, stroke: 1.5) { k in
    var path = Path()
    path.addArc(
      center: CGPoint(x: 8 * k, y: 8 * k), radius: 5 * k,
      startAngle: .degrees(0), endAngle: .degrees(311.35), clockwise: false)
    path.move(to: CGPoint(x: 13 * k, y: 2.8 * k))
    path.addLine(to: CGPoint(x: 13 * k, y: 5.2 * k))
    path.addLine(to: CGPoint(x: 10.6 * k, y: 5.2 * k))
    return [Part(path: path, fills: false, opacity: 1)]
  }

  /// 読み込み停止 `m4 4 8 8M12 4l-8 8`（stroke 1.5）。
  static let stop = Glyph(viewBox: 16, stroke: 1.5) { k in
    var path = Path()
    path.move(to: CGPoint(x: 4 * k, y: 4 * k))
    path.addLine(to: CGPoint(x: 12 * k, y: 12 * k))
    path.move(to: CGPoint(x: 12 * k, y: 4 * k))
    path.addLine(to: CGPoint(x: 4 * k, y: 12 * k))
    return [Part(path: path, fills: false, opacity: 1)]
  }

  /// HTTPS 鍵（12pt で使用。stroke 1.5）。
  static let lock = Glyph(viewBox: 16, stroke: 1.5) { k in
    var path = Path(
      roundedRect: CGRect(x: 3.5 * k, y: 7 * k, width: 9 * k, height: 6.5 * k),
      cornerRadius: 1.5 * k)
    path.move(to: CGPoint(x: 5.5 * k, y: 7 * k))
    path.addLine(to: CGPoint(x: 5.5 * k, y: 5 * k))
    path.addArc(
      center: CGPoint(x: 8 * k, y: 5 * k), radius: 2.5 * k,
      startAngle: .degrees(180), endAngle: .degrees(0), clockwise: false)
    path.addLine(to: CGPoint(x: 10.5 * k, y: 7 * k))
    return [Part(path: path, fills: false, opacity: 1)]
  }

  /// 全面 ⇄ 右シート切替: 外枠の角丸四角＋右半分の塗り（stroke 1.5）。
  static let sheetToggle = Glyph(viewBox: 16, stroke: 1.5) { k in
    let frame = Path(
      roundedRect: CGRect(x: 2.5 * k, y: 3 * k, width: 11 * k, height: 10 * k),
      cornerRadius: 1.8 * k)
    let sheet = Path(
      roundedRect: CGRect(x: 8.2 * k, y: 4.8 * k, width: 3.8 * k, height: 6.4 * k),
      cornerRadius: 0.8 * k)
    return [
      Part(path: frame, fills: false, opacity: 1),
      Part(path: sheet, fills: true, opacity: 0.75),
    ]
  }
}

/// ブラウザグリフを `size` 角に描く。
struct BrowserGlyphView: View {
  let glyph: BrowserGlyphs.Glyph
  let size: CGFloat
  let color: Color

  var body: some View {
    let k = size / glyph.viewBox
    let style = StrokeStyle(lineWidth: glyph.stroke * k, lineCap: .round, lineJoin: .round)
    ZStack {
      ForEach(Array(glyph.parts(k).enumerated()), id: \.offset) { _, part in
        if part.fills {
          part.path.fill(color.opacity(part.opacity))
        } else {
          part.path.stroke(color.opacity(part.opacity), style: style)
        }
      }
    }
    .frame(width: size, height: size)
  }
}
