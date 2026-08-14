import SwiftUI

/// フルウィンドウ overlay。Scrim（暗幕＋blur）＋上端 66px アンカーのカード。
/// カード幅= min(560, 窓幅−32)。scrim タップで閉じる。
/// カード高は窓高に束縛する（`layout` が上下の余白とカードの上限を逆算し、`PaletteCard` へ渡す）。
struct PaletteOverlay: View {
  @Bindable var model: PaletteModel
  /// カードから遡上する chrome（ヘッダ・ヒント等）の実測高。余白をどこまで譲るかの基準。
  @State private var chromeHeight: CGFloat = 0

  /// カード上端の窓上端からの距離・カードの基準幅（WorkspaceSwitcher）。
  private static let topAnchor: CGFloat = 66
  private let cardWidth: CGFloat = 560

  /// 窓が与えるカードの置き場所。上下の余白と、カードに許す高さ。
  struct CardLayout {
    let top: CGFloat
    let bottom: CGFloat
    let maxHeight: CGFloat
  }

  /// 窓高と chrome 実測から、上下の余白とカードの高さ上限を出す。
  ///
  /// 窓が「chrome ＋ 余白」を満たす間は上 66 / 下 16 に張り付く。足りなくなると**両者が同じ比率で**
  /// 詰まり、カードは chrome を切らずに済む（`maxHeight` は chrome を下回らない——窓自体が chrome を
  /// 割るときだけ窓高に一致する＝器の側では救えない退化域）。66:16 の比を保つので片側だけ潰れない。
  /// 新しい定数は 1 つも要らない: 66 と 16 は既存の値、chrome は実測。
  static func layout(windowHeight: CGFloat, chromeHeight: CGFloat) -> CardLayout {
    let margins = topAnchor + Theme.Space.bar
    let scale = min(1, max(0, windowHeight - chromeHeight) / margins)
    let top = topAnchor * scale
    let bottom = Theme.Space.bar * scale
    return CardLayout(top: top, bottom: bottom, maxHeight: max(0, windowHeight - top - bottom))
  }

  var body: some View {
    GeometryReader { geo in
      let layout = Self.layout(windowHeight: geo.size.height, chromeHeight: chromeHeight)
      ZStack(alignment: .top) {
        Scrim(strength: model.scrimStrength)
          .contentShape(Rectangle())
          .onTapGesture { model.onScrimTap() }
        PaletteCard(model: model, maxHeight: layout.maxHeight)
          .frame(width: min(cardWidth, geo.size.width - Theme.Space.bar * 2))
          .padding(.top, layout.top)
          .frame(maxWidth: .infinity, alignment: .top)
      }
    }
    .ignoresSafeArea()
    .onPreferenceChange(ChromeHeightKey.self) { chromeHeight = $0 }
    // 実マウス移動（NSEvent .mouseMoved）だけを拾ってモダリティを .pointer に落とす透明レイヤ。
    // スクロールで行がカーソル下を横切る SwiftUI onHover と違い、mouseMoved は物理移動でのみ出る。
    .overlay(MouseMovedDetector { model.inputModality = .pointer })
  }
}
