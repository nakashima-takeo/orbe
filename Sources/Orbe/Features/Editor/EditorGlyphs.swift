import SwiftUI

/// 骨の装飾グリフ（見本 editor/parts.tsx の SVG の写し）。viewBox 座標で組み、`k = size / viewBox` で
/// point 空間へ乗算する（`StatusGlyphShape` と同じ流儀。stroke 幅も SVG と同じく viewBox に比例する）。
/// 装飾グリフなので `AgentIconResolver` は読まない。
enum EditorGlyphs {
  struct Glyph {
    let viewBox: CGFloat
    let stroke: CGFloat
    /// `k` を受け、(path, opacity) の列を返す。
    let parts: (CGFloat) -> [(path: Path, opacity: Double)]
  }

  /// レールの「ファイル」（24 系・stroke 1.5）。前面の書類と、後ろに沈む 2 枚目の縁（opacity .8）。
  static let railFiles = Glyph(viewBox: 24, stroke: 1.5) { k in
    func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x * k, y: y * k) }
    var sheet = Path()
    sheet.move(to: p(8, 5.5))
    sheet.addLine(to: p(15, 5.5))
    sheet.addLine(to: p(18.5, 9))
    sheet.addArc(tangent1End: p(18.5, 19), tangent2End: p(7, 19), radius: k)
    sheet.addArc(tangent1End: p(7, 19), tangent2End: p(7, 5.5), radius: k)
    sheet.addArc(tangent1End: p(7, 5.5), tangent2End: p(15, 5.5), radius: k)
    sheet.closeSubpath()
    sheet.move(to: p(15, 5.5))
    sheet.addLine(to: p(15, 9))
    sheet.addLine(to: p(18.5, 9))
    var behind = Path()
    behind.move(to: p(5.5, 8.5))
    behind.addArc(tangent1End: p(5.5, 20.5), tangent2End: p(15, 20.5), radius: k)
    behind.addLine(to: p(15, 20.5))
    return [(sheet, 1), (behind, 0.8)]
  }

  /// 折りたたみのシェブロン `M6 4.5L10 8l-4 3.5`（stroke 1.3）。開いていると 90° 回す。
  static let chevron = Glyph(viewBox: 16, stroke: 1.3) { k in [(chevronPath(k), 1)] }

  /// パンくずの区切り（同じ形で stroke 1.5）。
  static let crumbChevron = Glyph(viewBox: 16, stroke: 1.5) { k in [(chevronPath(k), 1)] }

  private static func chevronPath(_ k: CGFloat) -> Path {
    var path = Path()
    path.move(to: CGPoint(x: 6 * k, y: 4.5 * k))
    path.addLine(to: CGPoint(x: 10 * k, y: 8 * k))
    path.addLine(to: CGPoint(x: 6 * k, y: 11.5 * k))
    return path
  }

  /// 新規ファイル: 角の折れた書類に ＋。
  static let newFile = Glyph(viewBox: 16, stroke: 1.2) { k in
    func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x * k, y: y * k) }
    var path = Path()
    path.move(to: p(9.5, 2.5))
    path.addArc(tangent1End: p(4, 2.5), tangent2End: p(4, 12.5), radius: k)
    path.addArc(tangent1End: p(4, 13.5), tangent2End: p(11, 13.5), radius: k)
    path.addArc(tangent1End: p(12, 13.5), tangent2End: p(12, 5), radius: k)
    path.addLine(to: p(12, 5))
    path.closeSubpath()
    path.move(to: p(9.5, 2.5))
    path.addLine(to: p(9.5, 5))
    path.addLine(to: p(12, 5))
    path.move(to: p(8, 7.5))
    path.addLine(to: p(8, 10.5))
    path.move(to: p(6.5, 9))
    path.addLine(to: p(9.5, 9))
    return [(path, 1)]
  }

  /// 新規フォルダ: タブ付きのフォルダに ＋。
  static let newFolder = Glyph(viewBox: 16, stroke: 1.2) { k in
    func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x * k, y: y * k) }
    var path = Path()
    path.move(to: p(2.5, 4.5))
    path.addLine(to: p(6.5, 4.5))
    path.addLine(to: p(8, 6))
    path.addLine(to: p(13.5, 6))
    path.addArc(tangent1End: p(13.5, 13), tangent2End: p(2.5, 13), radius: k)
    path.addArc(tangent1End: p(2.5, 13), tangent2End: p(2.5, 4.5), radius: k)
    path.closeSubpath()
    path.move(to: p(8, 8.2))
    path.addLine(to: p(8, 10.8))
    path.move(to: p(6.7, 9.5))
    path.addLine(to: p(9.3, 9.5))
    return [(path, 1)]
  }

  /// すべて折りたたむ: 重なった 2 枚の角丸に −。
  static let collapseAll = Glyph(viewBox: 16, stroke: 1.2) { k in
    func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x * k, y: y * k) }
    var path = Path(
      roundedRect: CGRect(x: 5.5 * k, y: 2.5 * k, width: 8 * k, height: 8 * k), cornerRadius: k)
    path.move(to: p(2.5, 5.5))
    path.addArc(tangent1End: p(2.5, 13.5), tangent2End: p(10.5, 13.5), radius: 2 * k)
    path.addLine(to: p(10.5, 13.5))
    path.move(to: p(7.5, 6.5))
    path.addLine(to: p(11.5, 6.5))
    return [(path, 1)]
  }

  /// ファイルタブの ×。見本には無い（ユーザー要望）ので、ブラウザ層の停止印と同じ 2 本の斜線。
  static let close = Glyph(viewBox: 16, stroke: 1.5) { k in
    func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x * k, y: y * k) }
    var path = Path()
    path.move(to: p(4, 4))
    path.addLine(to: p(12, 12))
    path.move(to: p(12, 4))
    path.addLine(to: p(4, 12))
    return [(path, 1)]
  }
}

/// グリフを `size` 角に stroke で描く。
struct EditorGlyphView: View {
  let glyph: EditorGlyphs.Glyph
  let size: CGFloat
  let color: Color

  var body: some View {
    let k = size / glyph.viewBox
    ZStack {
      ForEach(Array(glyph.parts(k).enumerated()), id: \.offset) { _, part in
        part.path.stroke(color.opacity(part.opacity), lineWidth: glyph.stroke * k)
      }
    }
    .frame(width: size, height: size)
  }
}
