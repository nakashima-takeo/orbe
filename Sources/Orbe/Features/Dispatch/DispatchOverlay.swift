import SwiftUI

/// フルウィンドウ overlay。strong scrim（暗幕＋blur）＋上端 54px アンカーの Dispatch カード。
/// カード幅= min(640, 窓幅−32)。scrim タップで閉じる。
struct DispatchOverlay: View {
  @Bindable var model: DispatchPaletteModel

  /// カード上端の窓上端からの距離・カードの基準幅（Dispatch 専用。汎用 PaletteOverlay の 66/560 とは別値）。
  private let topAnchor: CGFloat = 54
  private let cardWidth: CGFloat = 640

  var body: some View {
    GeometryReader { geo in
      ZStack(alignment: .top) {
        Scrim(strength: .strong)
          .contentShape(Rectangle())
          // 作成中・削除中は scrim タップも握り潰す（キーの Esc 閉じと同様。ここが抜けると実行中にカード外を
          // クリックで palette が閉じ、completion が palette 消失で取りこぼされ worktree が孤児化する）。
          .onTapGesture { if !model.isBusy { model.onDismiss() } }
        // カードは窓に収める（高さ上限＝窓高 − 70 相当）。上端アンカー＋下端に bar 分の
        // 余白を残した高さを上限に渡し、内部でリスト部が縮んで内部スクロールへ回る。
        DispatchCard(
          model: model,
          maxHeight: max(0, geo.size.height - topAnchor - Theme.Space.bar)
        )
        .frame(width: min(cardWidth, geo.size.width - Theme.Space.bar * 2))
        .padding(.top, topAnchor)
        .frame(maxWidth: .infinity, alignment: .top)
      }
    }
    .ignoresSafeArea()
    // 実マウス移動（NSEvent .mouseMoved）だけを拾ってモダリティを .pointer に落とす透明レイヤ
    // （汎用 PaletteOverlay と同じ機構）。スクロールで行がカーソル下を横切る SwiftUI onHover と違い、
    // mouseMoved は物理移動でのみ出るため、キー操作中の選択奪取が起きない。
    .overlay(MouseMovedDetector { model.inputModality = .pointer })
  }
}
