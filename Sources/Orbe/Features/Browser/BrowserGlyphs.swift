import SwiftUI

/// 内蔵ブラウザのツールバー・サイドバー・ポップオーバー用手作りグリフ（viewBox 比例方式）。
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

  /// サイドバー開閉 `M2.5 3.5h11v9h-11z M6 3.5v9`（stroke 1.5）。
  static let sidebar = Glyph(viewBox: 16, stroke: 1.5) { k in
    var path = Path(
      roundedRect: CGRect(x: 2.5 * k, y: 3.5 * k, width: 11 * k, height: 9 * k),
      cornerRadius: 1.6 * k)
    path.move(to: CGPoint(x: 6 * k, y: 3.5 * k))
    path.addLine(to: CGPoint(x: 6 * k, y: 12.5 * k))
    return [Part(path: path, fills: false, opacity: 1)]
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

  /// 追加 `+`（stroke 1.5）。
  static let plus = Glyph(viewBox: 16, stroke: 1.5) { k in
    var path = Path()
    path.move(to: CGPoint(x: 8 * k, y: 3.5 * k))
    path.addLine(to: CGPoint(x: 8 * k, y: 12.5 * k))
    path.move(to: CGPoint(x: 3.5 * k, y: 8 * k))
    path.addLine(to: CGPoint(x: 12.5 * k, y: 8 * k))
    return [Part(path: path, fills: false, opacity: 1)]
  }

  /// 行の閉じる `×`（stroke 1.6）。
  static let close = Glyph(viewBox: 16, stroke: 1.6) { k in
    var path = Path()
    path.move(to: CGPoint(x: 4.5 * k, y: 4.5 * k))
    path.addLine(to: CGPoint(x: 11.5 * k, y: 11.5 * k))
    path.move(to: CGPoint(x: 11.5 * k, y: 4.5 * k))
    path.addLine(to: CGPoint(x: 4.5 * k, y: 11.5 * k))
    return [Part(path: path, fills: false, opacity: 1)]
  }

  /// HTTPS / MCP 非公開の鍵（stroke 1.5）。
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

  /// シールド（MCP 読み取り権限）。
  static let shield = Glyph(viewBox: 16, stroke: 1.5) { k in
    var path = Path()
    path.move(to: CGPoint(x: 8 * k, y: 2 * k))
    path.addLine(to: CGPoint(x: 3 * k, y: 4 * k))
    path.addLine(to: CGPoint(x: 3 * k, y: 8 * k))
    path.addCurve(
      to: CGPoint(x: 8 * k, y: 14 * k),
      control1: CGPoint(x: 3 * k, y: 11.2 * k),
      control2: CGPoint(x: 5.2 * k, y: 13.4 * k))
    path.addCurve(
      to: CGPoint(x: 13 * k, y: 8 * k),
      control1: CGPoint(x: 10.8 * k, y: 13.4 * k),
      control2: CGPoint(x: 13 * k, y: 11.2 * k))
    path.addLine(to: CGPoint(x: 13 * k, y: 4 * k))
    path.closeSubpath()
    return [Part(path: path, fills: false, opacity: 1)]
  }

  /// チェックマーク。
  static let check = Glyph(viewBox: 16, stroke: 1.7) { k in
    var path = Path()
    path.move(to: CGPoint(x: 3.5 * k, y: 8.3 * k))
    path.addLine(to: CGPoint(x: 6.5 * k, y: 11.3 * k))
    path.addLine(to: CGPoint(x: 12.5 * k, y: 4.8 * k))
    return [Part(path: path, fills: false, opacity: 1)]
  }

  /// 編集（鉛筆）。
  static let pencil = Glyph(viewBox: 16, stroke: 1.4) { k in
    var path = Path()
    path.move(to: CGPoint(x: 10.8 * k, y: 2.8 * k))
    path.addLine(to: CGPoint(x: 13.2 * k, y: 5.2 * k))
    path.addLine(to: CGPoint(x: 5.8 * k, y: 12.6 * k))
    path.addLine(to: CGPoint(x: 3 * k, y: 13 * k))
    path.addLine(to: CGPoint(x: 3.4 * k, y: 10.2 * k))
    path.closeSubpath()
    return [Part(path: path, fills: false, opacity: 1)]
  }

  /// 削除（ゴミ箱）。
  static let trash = Glyph(viewBox: 16, stroke: 1.4) { k in
    var path = Path()
    path.move(to: CGPoint(x: 3 * k, y: 4.5 * k))
    path.addLine(to: CGPoint(x: 13 * k, y: 4.5 * k))
    path.move(to: CGPoint(x: 6 * k, y: 4.5 * k))
    path.addLine(to: CGPoint(x: 6 * k, y: 3 * k))
    path.addLine(to: CGPoint(x: 10 * k, y: 3 * k))
    path.addLine(to: CGPoint(x: 10 * k, y: 4.5 * k))
    path.move(to: CGPoint(x: 4.5 * k, y: 4.5 * k))
    path.addLine(to: CGPoint(x: 5.1 * k, y: 13 * k))
    path.addLine(to: CGPoint(x: 10.9 * k, y: 13 * k))
    path.addLine(to: CGPoint(x: 11.5 * k, y: 4.5 * k))
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

  // MARK: - スペースアイコン 6 種

  static let spacePerson = Glyph(viewBox: 18, stroke: 1.5) { k in
    var path = Path()
    path.addEllipse(in: CGRect(x: 6.2 * k, y: 3.4 * k, width: 5.6 * k, height: 5.6 * k))
    path.move(to: CGPoint(x: 3.5 * k, y: 15 * k))
    path.addCurve(
      to: CGPoint(x: 14.5 * k, y: 15 * k),
      control1: CGPoint(x: 3.5 * k, y: 11.2 * k),
      control2: CGPoint(x: 14.5 * k, y: 11.2 * k))
    return [Part(path: path, fills: false, opacity: 1)]
  }

  static let spaceBriefcase = Glyph(viewBox: 18, stroke: 1.5) { k in
    var path = Path(
      roundedRect: CGRect(x: 2.8 * k, y: 6.2 * k, width: 12.4 * k, height: 8 * k),
      cornerRadius: 1.6 * k)
    path.move(to: CGPoint(x: 6.5 * k, y: 6.2 * k))
    path.addLine(to: CGPoint(x: 6.5 * k, y: 4.4 * k))
    path.addQuadCurve(
      to: CGPoint(x: 7.5 * k, y: 3.4 * k), control: CGPoint(x: 6.5 * k, y: 3.4 * k))
    path.addLine(to: CGPoint(x: 10.5 * k, y: 3.4 * k))
    path.addQuadCurve(
      to: CGPoint(x: 11.5 * k, y: 4.4 * k), control: CGPoint(x: 11.5 * k, y: 3.4 * k))
    path.addLine(to: CGPoint(x: 11.5 * k, y: 6.2 * k))
    return [Part(path: path, fills: false, opacity: 1)]
  }

  static let spaceSearch = Glyph(viewBox: 18, stroke: 1.5) { k in
    var path = Path()
    path.addEllipse(in: CGRect(x: 3.2 * k, y: 3.2 * k, width: 9.6 * k, height: 9.6 * k))
    path.move(to: CGPoint(x: 11.6 * k, y: 11.6 * k))
    path.addLine(to: CGPoint(x: 15 * k, y: 15 * k))
    return [Part(path: path, fills: false, opacity: 1)]
  }

  static let spaceGlobe = Glyph(viewBox: 18, stroke: 1.5) { k in
    var path = Path()
    path.addEllipse(in: CGRect(x: 2.8 * k, y: 2.8 * k, width: 12.4 * k, height: 12.4 * k))
    path.addEllipse(in: CGRect(x: 6.2 * k, y: 2.8 * k, width: 5.6 * k, height: 12.4 * k))
    path.move(to: CGPoint(x: 2.8 * k, y: 9 * k))
    path.addLine(to: CGPoint(x: 15.2 * k, y: 9 * k))
    return [Part(path: path, fills: false, opacity: 1)]
  }

  static let spaceCode = Glyph(viewBox: 18, stroke: 1.5) { k in
    var path = Path()
    path.move(to: CGPoint(x: 6.5 * k, y: 5 * k))
    path.addLine(to: CGPoint(x: 2.8 * k, y: 9 * k))
    path.addLine(to: CGPoint(x: 6.5 * k, y: 13 * k))
    path.move(to: CGPoint(x: 11.5 * k, y: 5 * k))
    path.addLine(to: CGPoint(x: 15.2 * k, y: 9 * k))
    path.addLine(to: CGPoint(x: 11.5 * k, y: 13 * k))
    return [Part(path: path, fills: false, opacity: 1)]
  }

  static let spaceStar = Glyph(viewBox: 18, stroke: 1.45) { k in
    let points: [(CGFloat, CGFloat)] = [
      (9, 2.6), (10.9, 6.6), (15.3, 7.2), (12.1, 10.3), (12.9, 14.7),
      (9, 12.6), (5.1, 14.7), (5.9, 10.3), (2.7, 7.2), (7.1, 6.6),
    ]
    var path = Path()
    path.move(to: CGPoint(x: points[0].0 * k, y: points[0].1 * k))
    for point in points.dropFirst() {
      path.addLine(to: CGPoint(x: point.0 * k, y: point.1 * k))
    }
    path.closeSubpath()
    return [Part(path: path, fills: false, opacity: 1)]
  }

  static func spaceIcon(_ icon: BrowserSpaceIcon) -> Glyph {
    switch icon {
    case .person: spacePerson
    case .briefcase: spaceBriefcase
    case .search: spaceSearch
    case .globe: spaceGlobe
    case .code: spaceCode
    case .star: spaceStar
    case .local: spaceGlobe
    }
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
