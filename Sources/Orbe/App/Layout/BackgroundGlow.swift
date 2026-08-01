import SwiftUI

/// AppShell 最背面に敷く装飾層。地色の上に電紫＋青のラジアルを 2 枚重ね、chrome 余白ににじませる。
/// 幾何は `radial-gradient(1000px 400px at 20% -10%, …)` ＋ `(800px 500px at 100% 100%, …)` 相当。
/// 同色 α0.10→α0 の線形グラデーションを
/// `drawingGroup(colorMode: .nonLinear)`（ガンマ空間合成）でまとめて描く。非対話（hit-test 透過）。
struct BackgroundGlow: View {
  @Environment(\.chromeTranslucency) private var translucency

  var body: some View {
    GeometryReader { geo in
      ZStack {
        // 透過時は不透明ベースを敷かない（端末の透明ピクセルをデスクトップまで抜く根本解決）。
        // glow はブランドのアイデンティティとして透過時も薄く残す。
        if !translucency.translucent { Color.theme.bgBase }
        glow(color: Theme.Glass.glowPrimary, rx: 1000, ry: 400)
          .position(x: geo.size.width * 0.2, y: -geo.size.height * 0.1)
        glow(color: Theme.Glass.glowSecondary, rx: 800, ry: 500)
          .position(x: geo.size.width, y: geo.size.height)
      }
      // 不透明時のみ不透明ラスタ化（CSS 合成則の踏襲）。透過時は alpha を通す（opaque:false）。
      .drawingGroup(opaque: !translucency.translucent, colorMode: .nonLinear)
    }
    .ignoresSafeArea()
    .allowsHitTesting(false)
  }

  /// 楕円ラジアル 1 枚（半径 rx×ry・中心 α→縁 α0 の線形減衰）。
  private func glow(color: NSColor, rx: CGFloat, ry: CGFloat) -> some View {
    let base = Color(nsColor: color)
    return Ellipse()
      .fill(
        EllipticalGradient(
          colors: [base, base.opacity(0)],
          center: .center, startRadiusFraction: 0, endRadiusFraction: 0.5)
      )
      .frame(width: rx * 2, height: ry * 2)
  }
}
