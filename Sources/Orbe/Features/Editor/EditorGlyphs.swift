import SwiftUI

/// 骨の装飾グリフ（見本 editor/parts.tsx の SVG の写し）。viewBox 座標で組み、`k = size / viewBox` で
/// point 空間へ乗算する（`StatusGlyphShape` と同じ流儀。stroke 幅も SVG と同じく viewBox に比例する）。
/// 装飾グリフなので `AgentIconResolver` は読まない。
enum EditorGlyphs {
  struct Glyph {
    let viewBox: CGFloat
    let stroke: CGFloat
    /// 塗りの印（見本の `fill="currentColor"`）。`stroke` は使わない。
    var fills = false
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

  /// レールの「検索」（24 系・stroke 1.6。見本 SearchIcon）。
  static let railSearch = Glyph(viewBox: 24, stroke: 1.6) { k in
    var path = Path(ellipseIn: CGRect(x: 5.5 * k, y: 5.5 * k, width: 11 * k, height: 11 * k))
    path.move(to: CGPoint(x: 15.5 * k, y: 15.5 * k))
    path.addLine(to: CGPoint(x: 20 * k, y: 20 * k))
    return [(path, 1)]
  }

  /// レールの「ソース管理」（24 系・stroke 1.5。見本 RailGitIcon）。
  static let railGit = Glyph(viewBox: 24, stroke: 1.5) { k in
    func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x * k, y: y * k) }
    var path = Path()
    for (x, y) in [(7.5, 6.5), (7.5, 17.5), (16.5, 9.0)] as [(CGFloat, CGFloat)] {
      path.addEllipse(in: CGRect(x: (x - 2) * k, y: (y - 2) * k, width: 4 * k, height: 4 * k))
    }
    path.move(to: p(7.5, 8.5))
    path.addLine(to: p(7.5, 15.5))
    path.move(to: p(16.5, 11))
    path.addCurve(to: p(10.5, 15), control1: p(16.5, 14), control2: p(13.5, 14.5))
    return [(path, 1)]
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

  /// すべて展開: 重なった 2 枚の角丸に ＋（`collapseAll` の対）。
  static let expandAll = Glyph(viewBox: 16, stroke: 1.2) { k in
    var parts = collapseAll.parts(k)
    var plus = Path()
    plus.move(to: CGPoint(x: 9.5 * k, y: 4.5 * k))
    plus.addLine(to: CGPoint(x: 9.5 * k, y: 8.5 * k))
    parts.append((plus, 1))
    return parts
  }

  /// 更新: 開いた円弧と矢じり（見本 RefreshIcon `M13 8a5 5 0 1 1-1.7-3.75` `M13 2.8v2.4h-2.4`）。
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

  /// 停止: 円に四角（見本に無い。検索が 2 秒を超えると更新と入れ替わる）。
  static let stop = Glyph(viewBox: 16, stroke: 1.2) { k in
    var path = Path(ellipseIn: CGRect(x: 2.5 * k, y: 2.5 * k, width: 11 * k, height: 11 * k))
    path.addRect(CGRect(x: 6 * k, y: 6 * k, width: 4 * k, height: 4 * k))
    return [(path, 1)]
  }

  /// クリア: 斜線の入った円（見本 ClearIcon）。
  static let clear = Glyph(viewBox: 16, stroke: 1.2) { k in
    var path = Path(ellipseIn: CGRect(x: 2.5 * k, y: 2.5 * k, width: 11 * k, height: 11 * k))
    path.move(to: CGPoint(x: 4.2 * k, y: 4.2 * k))
    path.addLine(to: CGPoint(x: 11.8 * k, y: 11.8 * k))
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

extension EditorGlyphs {
  /// コミット: レ点（見本 CheckIcon `M3 8.5l3.2 3L13 4.5`。stroke 1.3）。
  static let check = Glyph(viewBox: 16, stroke: 1.3) { k in [(checkPath(k), 1)] }

  /// コミットボタンのレ点（同じ形で stroke 1.6）。
  static let commitCheck = Glyph(viewBox: 16, stroke: 1.6) { k in [(checkPath(k), 1)] }

  private static func checkPath(_ k: CGFloat) -> Path {
    var path = Path()
    path.move(to: CGPoint(x: 3 * k, y: 8.5 * k))
    path.addLine(to: CGPoint(x: 6.2 * k, y: 11.5 * k))
    path.addLine(to: CGPoint(x: 13 * k, y: 4.5 * k))
    return path
  }

  /// その他: 3 つの点（見本 MoreIcon。塗り）。
  static let more = Glyph(viewBox: 16, stroke: 0, fills: true) { k in
    var path = Path()
    for x in [3.5, 8, 12.5] as [CGFloat] {
      path.addEllipse(in: CGRect(x: (x - 1.2) * k, y: 6.8 * k, width: 2.4 * k, height: 2.4 * k))
    }
    return [(path, 1)]
  }

  /// 下向きのシェブロン（見本 ChevDownIcon `M4 6.5L8 10l4-3.5`。stroke 1.5）。
  static let chevronDown = Glyph(viewBox: 16, stroke: 1.5) { k in
    var path = Path()
    path.move(to: CGPoint(x: 4 * k, y: 6.5 * k))
    path.addLine(to: CGPoint(x: 8 * k, y: 10 * k))
    path.addLine(to: CGPoint(x: 12 * k, y: 6.5 * k))
    return [(path, 1)]
  }

  /// ファイルを開く: 書類から右上へ抜ける矢印（見本 OpenEditorIcon。stroke 1.2）。
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

  /// 変更を破棄: 戻る矢印（見本 DiscardIcon。stroke 1.2）。
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

  /// ステージ: ＋（見本 PlusIcon。stroke 1.3）。
  static let plus = Glyph(viewBox: 16, stroke: 1.3) { k in
    var path = Path()
    path.move(to: CGPoint(x: 8 * k, y: 4.5 * k))
    path.addLine(to: CGPoint(x: 8 * k, y: 11.5 * k))
    path.move(to: CGPoint(x: 4.5 * k, y: 8 * k))
    path.addLine(to: CGPoint(x: 11.5 * k, y: 8 * k))
    return [(path, 1)]
  }

  /// ステージを解除: −（見本に無い。＋と同じ太さ・長さ）。
  static let minus = Glyph(viewBox: 16, stroke: 1.3) { k in
    var path = Path()
    path.move(to: CGPoint(x: 4.5 * k, y: 8 * k))
    path.addLine(to: CGPoint(x: 11.5 * k, y: 8 * k))
    return [(path, 1)]
  }

  /// 同期: 下りと上りの矢印（見本に無い）。
  static let sync = Glyph(viewBox: 16, stroke: 1.5) { k in
    func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x * k, y: y * k) }
    var path = Path()
    path.move(to: p(5, 2))
    path.addLine(to: p(5, 12))
    path.move(to: p(2.5, 9.5))
    path.addLine(to: p(5, 12))
    path.addLine(to: p(7.5, 9.5))
    path.move(to: p(11, 14))
    path.addLine(to: p(11, 4))
    path.move(to: p(8.5, 6.5))
    path.addLine(to: p(11, 4))
    path.addLine(to: p(13.5, 6.5))
    return [(path, 1)]
  }

  /// ブランチを公開: 受け皿から上がる矢印（見本に無い）。
  static let publish = Glyph(viewBox: 16, stroke: 1.4) { k in
    func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x * k, y: y * k) }
    var path = Path()
    path.move(to: p(8, 10.5))
    path.addLine(to: p(8, 2.5))
    path.move(to: p(5, 5.5))
    path.addLine(to: p(8, 2.5))
    path.addLine(to: p(11, 5.5))
    path.move(to: p(3, 9.5))
    path.addLine(to: p(3, 13))
    path.addLine(to: p(13, 13))
    path.addLine(to: p(13, 9.5))
    return [(path, 1)]
  }

  /// 実行中の帯の「止める」: 角の丸い四角（見本に無い。塗り）。
  static let stopSquare = Glyph(viewBox: 10, stroke: 0, fills: true) { k in
    [(Path(roundedRect: CGRect(x: k, y: k, width: 8 * k, height: 8 * k), cornerRadius: k), 1)]
  }

  /// ブランチ（見本 BranchGlyph の形を線で。小さい寸法で使うので塗りの細部は持たない）。
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
