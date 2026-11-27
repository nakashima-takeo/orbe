import SwiftUI

/// 骨の装飾グリフ。viewBox 座標で組み、`k = size / viewBox` で point 空間へ乗算する
/// （`StatusGlyphShape` と同じ流儀。stroke 幅も SVG と同じく viewBox に比例する）。
/// 装飾グリフなので `AgentIconResolver` は読まない。
enum EditorGlyphs {
  struct Glyph {
    let viewBox: CGFloat
    let stroke: CGFloat
    /// 塗りの印（線ではなく塗りつぶす）。`stroke` は使わない。
    var fills = false
    /// `k` を受け、(path, opacity) の列を返す。
    let parts: (CGFloat) -> [(path: Path, opacity: Double)]
  }

  /// 上のバーの左の列の開閉 `M2.5 3.5h11v9h-11zM6 3.5v9`（stroke 1.4）。
  static let sidebarToggle = Glyph(viewBox: 16, stroke: 1.4) { k in
    var path = Path(CGRect(x: 2.5 * k, y: 3.5 * k, width: 11 * k, height: 9 * k))
    path.move(to: CGPoint(x: 6 * k, y: 3.5 * k))
    path.addLine(to: CGPoint(x: 6 * k, y: 12.5 * k))
    return [(path, 1)]
  }

  /// キーの印の ⌥ `M2.25 3.5H6l4.25 9h3.5M9.75 3.5h4`（stroke 1.45）。
  static let optionKey = Glyph(viewBox: 16, stroke: 1.45) { k in
    func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x * k, y: y * k) }
    var path = Path()
    path.move(to: p(2.25, 3.5))
    path.addLine(to: p(6, 3.5))
    path.addLine(to: p(10.25, 12.5))
    path.addLine(to: p(13.75, 12.5))
    path.move(to: p(9.75, 3.5))
    path.addLine(to: p(13.75, 3.5))
    return [(path, 1)]
  }

  /// 折りたたみのシェブロン `M6 4.5L10 8l-4 3.5`（stroke 1.3）。開いていると 90° 回す。
  static let chevron = Glyph(viewBox: 16, stroke: 1.3) { k in [(chevronPath(k), 1)] }

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

  /// すべて展開: 重なった 2 枚の角丸に ＋（`collapseAll` の対）。
  static let expandAll = Glyph(viewBox: 16, stroke: 1.2) { k in
    var parts = collapseAll.parts(k)
    var plus = Path()
    plus.move(to: CGPoint(x: 9.5 * k, y: 4.5 * k))
    plus.addLine(to: CGPoint(x: 9.5 * k, y: 8.5 * k))
    parts.append((plus, 1))
    return parts
  }

  /// 更新: 開いた円弧と矢じり（`M13 8a5 5 0 1 1-1.7-3.75` `M13 2.8v2.4h-2.4`）。
  static let refresh = Glyph(viewBox: 16, stroke: 1.2) { k in
    var path = Path()
    path.addArc(
      center: CGPoint(x: 8 * k, y: 8 * k), radius: 5 * k, startAngle: .degrees(0),
      endAngle: .degrees(311.35), clockwise: false)
    path.move(to: CGPoint(x: 13 * k, y: 2.8 * k))
    path.addLine(to: CGPoint(x: 13 * k, y: 5.2 * k))
    path.addLine(to: CGPoint(x: 10.6 * k, y: 5.2 * k))
    return [(path, 1)]
  }
}

extension EditorGlyphs {
  /// 承認: レ点（`M3 8.5l3.2 3L13 4.5`。stroke 1.3）。
  static let check = Glyph(viewBox: 16, stroke: 1.3) { k in [(checkPath(k), 1)] }

  /// チェックボックスのレ点（同じ形で stroke 2.2）。
  static let checkboxCheck = Glyph(viewBox: 16, stroke: 2.2) { k in [(checkPath(k), 1)] }

  /// PR の頭の帯のレ点（同じ形で stroke 1.6）。
  static let bandCheck = Glyph(viewBox: 16, stroke: 1.6) { k in [(checkPath(k), 1)] }

  private static func checkPath(_ k: CGFloat) -> Path {
    var path = Path()
    path.move(to: CGPoint(x: 3 * k, y: 8.5 * k))
    path.addLine(to: CGPoint(x: 6.2 * k, y: 11.5 * k))
    path.addLine(to: CGPoint(x: 13 * k, y: 4.5 * k))
    return path
  }

  /// その他: 3 つの点（塗り）。
  static let more = Glyph(viewBox: 16, stroke: 0, fills: true) { k in
    var path = Path()
    for x in [3.5, 8, 12.5] as [CGFloat] {
      path.addEllipse(in: CGRect(x: (x - 1.2) * k, y: 6.8 * k, width: 2.4 * k, height: 2.4 * k))
    }
    return [(path, 1)]
  }

  /// 下向きのシェブロン（`M4 6.5L8 10l4-3.5`。stroke 1.5）。
  static let chevronDown = Glyph(viewBox: 16, stroke: 1.5) { k in
    var path = Path()
    path.move(to: CGPoint(x: 4 * k, y: 6.5 * k))
    path.addLine(to: CGPoint(x: 8 * k, y: 10 * k))
    path.addLine(to: CGPoint(x: 12 * k, y: 6.5 * k))
    return [(path, 1)]
  }

  /// 閉じる × `m4 4 8 8M12 4l-8 8`（stroke 1.4）。
  static let close = Glyph(viewBox: 16, stroke: 1.4) { k in
    var path = Path()
    path.move(to: CGPoint(x: 4 * k, y: 4 * k))
    path.addLine(to: CGPoint(x: 12 * k, y: 12 * k))
    path.move(to: CGPoint(x: 12 * k, y: 4 * k))
    path.addLine(to: CGPoint(x: 4 * k, y: 12 * k))
    return [(path, 1)]
  }

  /// キーの印の ↵ `M13 3.25v3.5a2 2 0 0 1-2 2H3.25M6.25 5.75l-3 3 3 3`（stroke 1.45）。
  static let returnKey = Glyph(viewBox: 16, stroke: 1.45) { k in
    func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x * k, y: y * k) }
    var path = Path()
    path.move(to: p(13, 3.25))
    path.addLine(to: p(13, 6.75))
    path.addArc(tangent1End: p(13, 8.75), tangent2End: p(11, 8.75), radius: 2 * k)
    path.addLine(to: p(3.25, 8.75))
    path.move(to: p(6.25, 5.75))
    path.addLine(to: p(3.25, 8.75))
    path.addLine(to: p(6.25, 11.75))
    return [(path, 1)]
  }

  /// キーの印の → `M3 8h9M8.5 4.5 12 8l-3.5 3.5`（stroke 1.45）。← はその左右の反転。
  static let arrowRight = Glyph(viewBox: 16, stroke: 1.45) { k in
    [(arrowPath(k, flipped: false), 1)]
  }
  static let arrowLeft = Glyph(viewBox: 16, stroke: 1.45) { k in [(arrowPath(k, flipped: true), 1)]
  }

  private static func arrowPath(_ k: CGFloat, flipped: Bool) -> Path {
    func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
      CGPoint(x: (flipped ? 16 - x : x) * k, y: y * k)
    }
    var path = Path()
    path.move(to: p(3, 8))
    path.addLine(to: p(12, 8))
    path.move(to: p(8.5, 4.5))
    path.addLine(to: p(12, 8))
    path.addLine(to: p(8.5, 11.5))
    return path
  }

  /// ファイルを開く: 書類から右上へ抜ける矢印（stroke 1.2）。
  static let openFile = Glyph(viewBox: 16, stroke: 1.2) { k in
    func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x * k, y: y * k) }
    var path = Path()
    path.move(to: p(9, 2.5))
    path.addArc(tangent1End: p(4, 2.5), tangent2End: p(4, 12.5), radius: k)
    path.addArc(tangent1End: p(4, 13.5), tangent2End: p(11, 13.5), radius: k)
    path.addArc(tangent1End: p(12, 13.5), tangent2End: p(12, 7.5), radius: k)
    path.addLine(to: p(12, 7.5))
    path.move(to: p(8.5, 7.5))
    path.addLine(to: p(13, 3))
    path.move(to: p(10.2, 3))
    path.addLine(to: p(13, 3))
    path.addLine(to: p(13, 5.8))
    return [(path, 1)]
  }

  /// 変更を破棄: 戻る矢印（stroke 1.2）。
  static let discard = Glyph(viewBox: 16, stroke: 1.2) { k in
    func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x * k, y: y * k) }
    var path = Path()
    path.move(to: p(4.5, 6.5))
    path.addLine(to: p(10, 6.5))
    path.addArc(
      center: p(10, 9.5), radius: 3 * k, startAngle: .degrees(-90), endAngle: .degrees(90),
      clockwise: false)
    path.addLine(to: p(6.5, 12.5))
    path.move(to: p(7, 4))
    path.addLine(to: p(4.5, 6.5))
    path.addLine(to: p(7, 9))
    return [(path, 1)]
  }

  /// ステージ: ＋（stroke 1.3）。
  static let plus = Glyph(viewBox: 16, stroke: 1.3) { k in
    var path = Path()
    path.move(to: CGPoint(x: 8 * k, y: 4.5 * k))
    path.addLine(to: CGPoint(x: 8 * k, y: 11.5 * k))
    path.move(to: CGPoint(x: 4.5 * k, y: 8 * k))
    path.addLine(to: CGPoint(x: 11.5 * k, y: 8 * k))
    return [(path, 1)]
  }

  /// ステージを解除: −（＋と同じ太さ・長さ）。
  static let minus = Glyph(viewBox: 16, stroke: 1.3) { k in
    var path = Path()
    path.move(to: CGPoint(x: 4.5 * k, y: 8 * k))
    path.addLine(to: CGPoint(x: 11.5 * k, y: 8 * k))
    return [(path, 1)]
  }

  /// 同期の先行 ↑ `M8 12.5v-9M4.5 7 8 3.5 11.5 7` と遅れ ↓（その上下の反転）。stroke 1.5。
  static let arrowUp = Glyph(viewBox: 16, stroke: 1.5) { k in
    [(verticalArrowPath(k, down: false), 1)]
  }
  static let arrowDown = Glyph(viewBox: 16, stroke: 1.5) { k in
    [(verticalArrowPath(k, down: true), 1)]
  }

  private static func verticalArrowPath(_ k: CGFloat, down: Bool) -> Path {
    func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x * k, y: (down ? 16 - y : y) * k) }
    var path = Path()
    path.move(to: p(8, 12.5))
    path.addLine(to: p(8, 3.5))
    path.move(to: p(4.5, 7))
    path.addLine(to: p(8, 3.5))
    path.addLine(to: p(11.5, 7))
    return path
  }

  /// 警告: 三角と感嘆符 `M8 2.5 14.2 13H1.8zM8 6.6v3M8 11.3v.2`（stroke 1.5）。
  static let warning = Glyph(viewBox: 16, stroke: 1.5) { k in
    func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x * k, y: y * k) }
    var path = Path()
    path.move(to: p(8, 2.5))
    path.addLine(to: p(14.2, 13))
    path.addLine(to: p(1.8, 13))
    path.closeSubpath()
    path.move(to: p(8, 6.6))
    path.addLine(to: p(8, 9.6))
    path.move(to: p(8, 11.3))
    path.addLine(to: p(8, 11.5))
    return [(path, 1)]
  }

  /// ブランチ（線描き。小さい寸法で使うので塗りの細部は持たない）。
  static let branch = Glyph(viewBox: 16, stroke: 1.5) { k in
    func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x * k, y: y * k) }
    var path = Path()
    for (x, y) in [(3.75, 3.25), (3.75, 12.75), (12.75, 12.75)] as [(CGFloat, CGFloat)] {
      path.addEllipse(
        in: CGRect(x: (x - 1.5) * k, y: (y - 1.5) * k, width: 3 * k, height: 3 * k))
    }
    path.move(to: p(3.75, 4.75))
    path.addLine(to: p(3.75, 11.25))
    path.move(to: p(12.75, 11.25))
    path.addLine(to: p(12.75, 5))
    path.addArc(tangent1End: p(12.75, 3.25), tangent2End: p(11, 3.25), radius: 1.5 * k)
    path.addLine(to: p(8, 3.25))
    path.move(to: p(9.5, 1.5))
    path.addLine(to: p(7.75, 3.25))
    path.addLine(to: p(9.5, 5))
    return [(path, 1)]
  }
}

/// グリフを `size` 角に stroke で描く（塗りの印は塗る）。
struct EditorGlyphView: View {
  let glyph: EditorGlyphs.Glyph
  let size: CGFloat
  let color: Color

  var body: some View {
    let k = size / glyph.viewBox
    ZStack {
      ForEach(Array(glyph.parts(k).enumerated()), id: \.offset) { _, part in
        if glyph.fills {
          part.path.fill(color.opacity(part.opacity))
        } else {
          part.path.stroke(color.opacity(part.opacity), lineWidth: glyph.stroke * k)
        }
      }
    }
    .frame(width: size, height: size)
  }
}
