import SwiftUI

/// フルウィンドウ overlay。Scrim（暗幕＋blur）＋上端 66px アンカーのカード。
/// カード幅= min(560, 窓幅−32)。scrim タップで閉じる。
struct PaletteOverlay: View {
  @Bindable var model: PaletteModel

  /// カード上端の窓上端からの距離・カードの基準幅（WorkspaceSwitcher）。
  private let topAnchor: CGFloat = 66
  private let cardWidth: CGFloat = 560

  var body: some View {
    GeometryReader { geo in
      ZStack(alignment: .top) {
        Scrim(strength: model.scrimStrength)
          .contentShape(Rectangle())
          .onTapGesture { model.onScrimTap() }
        PaletteCard(model: model)
          .frame(width: min(cardWidth, geo.size.width - Theme.Space.bar * 2))
          .padding(.top, topAnchor)
          .frame(maxWidth: .infinity, alignment: .top)
      }
    }
    .ignoresSafeArea()
    // 実マウス移動（NSEvent .mouseMoved）だけを拾ってモダリティを .pointer に落とす透明レイヤ。
    // スクロールで行がカーソル下を横切る SwiftUI onHover と違い、mouseMoved は物理移動でのみ出る。
    .overlay(MouseMovedDetector { model.inputModality = .pointer })
  }
}
