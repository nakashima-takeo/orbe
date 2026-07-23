import SwiftUI

/// `NSVisualEffectView` を最小ラップした representable。同一ウィンドウ内の背後をぼかす。
/// `.ultraThinMaterial` 等の SwiftUI Material は blur 半径も色調も固定で任意の色調へ寄せられないため不採用。
struct VisualEffectView: NSViewRepresentable {
  var material: NSVisualEffectView.Material

  func makeNSView(context: Context) -> NSVisualEffectView {
    let v = NSVisualEffectView()
    v.blendingMode = .withinWindow  // 同一ウィンドウ内の背後（＝端末）をぼかす
    v.state = .active
    v.material = material
    return v
  }

  func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
    nsView.material = material
  }
}

/// Orbe の再利用パネル器。背後を `VisualEffectView` でぼかし、surface tint を重ね、
/// 1px 枠・角丸・elevation を持つ。全パネル共通の基盤。
struct GlassPanel<Content: View>: View {
  @Environment(\.chromeTranslucency) private var translucency
  var level: Theme.GlassLevel = .panel
  /// 角丸の上書き（nil で level 既定）。補完候補パネル（radius 8）等のコンポーネント個別値に使う。
  var cornerRadius: CGFloat?
  /// blur material の上書き（nil で level 既定）。Dispatch は面/枠が popup 級（α.90・.10/.14）でも
  /// blur は panel 級（24px）という組み合わせ。level だけでは表せないので明示ノブで寄せる。
  var materialOverride: NSVisualEffectView.Material?
  /// 影の上書き（nil で level 既定）。上と同じく Dispatch の大型フローティング影（panel 級）を指定する。
  var elevationOverride: Theme.ElevationLevel?
  /// 枠の上書き（nil で level 既定）。Attention パレットは面が popup 級（α.90）でも枠は panel 級（.08/.12）。
  var borderOverride: Theme.GlassLevel?
  @ViewBuilder let content: () -> Content

  /// blur 半径は material に固定（`--blur-panel: 24px` の厳密一致は原理不可）。見本に最も近い material を採る。
  private var material: NSVisualEffectView.Material {
    if let materialOverride { return materialOverride }
    switch level {
    case .panel, .settings: return .hudWindow
    case .popup: return .menu
    }
  }

  private var elevation: Theme.ElevationLevel {
    elevationOverride ?? (level == .popup ? .popup : .panel)
  }

  var body: some View {
    let shape = RoundedRectangle(
      cornerRadius: cornerRadius ?? Theme.Glass.radius(level), style: .circular)
    content()
      .background {
        ZStack {
          // blur=ON（＝すりガラス希望）か不透明時のみ VisualEffectView で背後を鎮める。
          // 透過かつ blur=OFF は素通し半透明——背後（デスクトップ）を既存 CGS window ブラーに委ねる。
          if !translucency.translucent || translucency.blur {
            VisualEffectView(material: material)
          }
          // surface tint オーバーレイ。透過時は effectiveOpacity で薄め、端末・chrome と veil 濃度を揃える。
          Color(nsColor: Theme.Glass.surface(level)).opacity(translucency.effectiveOpacity)
        }
      }
      .clipShape(shape)
      .overlay(
        shape.strokeBorder(
          Color(nsColor: Theme.Glass.border(borderOverride ?? level)),
          lineWidth: Theme.Stroke.hairline)
      )
      .elevation(elevation)
  }
}

#if DEBUG
  #Preview("GlassPanel") {
    // `.withinWindow` は背後に実体が無いとぼかす対象が無いため、モック端末を backdrop に敷く。
    ZStack {
      VStack(alignment: .leading, spacing: 2) {
        ForEach(0..<24, id: \.self) { i in
          Text("\(i)  let value = compute(\(i)) // backdrop sample")
            .font(Font.theme.code)
            .foregroundStyle(Color.theme.textSecondary)
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      .padding(Theme.Space.bar)
      .background(Color.theme.bgSunken)

      HStack(spacing: Theme.Space.phrase) {
        panel(.panel, "panel .72")
        panel(.settings, "settings .85")
        panel(.popup, "popup .90")
      }
      .padding(Theme.Space.phrase)
    }
    .frame(width: 720, height: 420)
  }

  @ViewBuilder private func panel(_ level: Theme.GlassLevel, _ label: String) -> some View {
    GlassPanel(level: level) {
      VStack(alignment: .leading, spacing: Theme.Space.step) {
        Text(label)
          .font(Font.theme.title)
          .foregroundStyle(Color.theme.textPrimary)
        Text("The quick brown fox")
          .font(Font.theme.body)
          .foregroundStyle(Color.theme.textSecondary)
      }
      .padding(Theme.Space.bar)
      .frame(width: 180, alignment: .leading)
    }
  }
#endif
