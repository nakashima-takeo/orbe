import SwiftUI

/// ◐ ブランドグリフの Path 描画（app icon / design の OrbeGlyph SVG と同じシンボル・
/// 外半径:内半径 = 15:11.777、viewBox 32 座標を size へ等倍）。塗りは既定でテーマ非依存の
/// ブランドグラデ（`Color.theme.glyphGradient`）、`color` 指定で単色（メニューバーの
/// template image 相当＝前景モノクロ描画に使う）。
/// フォント任せの字形（`Text("◐")`）と違い、フォールバック解決に依らず小サイズでも形が保たれる
/// （メニューバーアイテムが使う。パレットヘッダの既存 Text 描画は変えない）。
struct OrbeMarkGlyph: View {
  var size: CGFloat
  /// 単色塗り（nil＝ブランドグラデ）。
  var color: Color?

  var body: some View {
    OrbeMarkShape()
      .fill(
        color.map(AnyShapeStyle.init) ?? AnyShapeStyle(Color.theme.glyphGradient),
        style: FillStyle(eoFill: true)
      )
      .frame(width: size, height: size)
  }
}

/// OrbeGlyph の SVG path（M1 16 a15 15 … / M16 4.223 A11.777 … evenodd）の移植。
/// 外円（r15）から右半分の内半円（r11.777）を evenodd で抜く。
struct OrbeMarkShape: Shape {
  func path(in rect: CGRect) -> Path {
    let k = rect.width / 32
    var path = Path()
    path.addEllipse(in: CGRect(x: 1 * k, y: 1 * k, width: 30 * k, height: 30 * k))
    // 内側の抜き: (16, 4.223) → 右回りに (16, 27.777) の半円弧 → 直線で閉じる。
    path.move(to: CGPoint(x: 16 * k, y: 4.223 * k))
    path.addArc(
      center: CGPoint(x: 16 * k, y: 16 * k), radius: 11.777 * k,
      startAngle: .degrees(-90), endAngle: .degrees(90), clockwise: false)
    path.closeSubpath()
    return path
  }
}

#if DEBUG
  #Preview("OrbeMarkGlyph") {
    HStack(spacing: Theme.Space.span) {
      OrbeMarkGlyph(size: 15)
      OrbeMarkGlyph(size: 24)
      OrbeMarkGlyph(size: 48)
    }
    .padding(Theme.Space.phrase)
    .background(Color.theme.bgBase)
  }
#endif
