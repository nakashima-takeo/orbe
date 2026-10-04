import SwiftUI

/// タスク画面のフルウィンドウ overlay。strong scrim（暗幕＋blur）＋上端アンカーのカード。scrim タップで閉じる。
/// カードは見本の寸法（1080×795）を上限に窓へ収める。詳細の欄は見本の比率（カードの 1/3）で一緒に縮むが、
/// 選択式の値が並びきる幅（300）までで止め、それより狭い窓では一覧と半分ずつ分ける。
struct TaskPaletteOverlay: View {
  @Bindable var model: TaskPaletteModel

  private let topAnchor: CGFloat = 72
  private let bottomGap: CGFloat = 32
  private let cardSize = CGSize(width: 1080, height: 795)

  var body: some View {
    GeometryReader { geo in
      let width = max(0, min(cardSize.width, geo.size.width - Theme.Space.bar * 2))
      ZStack(alignment: .top) {
        Scrim(strength: .strong)
          .contentShape(Rectangle())
          .onTapGesture { model.onDismiss() }
        TaskPaletteCard(model: model, detailWidth: min(width / 2, max(300, width / 3)))
          .frame(
            width: width,
            height: max(0, min(cardSize.height, geo.size.height - topAnchor - bottomGap))
          )
          .padding(.top, topAnchor)
          .frame(maxWidth: .infinity, alignment: .top)
      }
    }
    .ignoresSafeArea()
    // 実マウス移動だけを拾ってモダリティを .pointer に落とす（スクロールで行がカーソル下を横切っても
    // 選択を奪わない。汎用 PaletteOverlay と同じ機構）。
    .overlay(MouseMovedDetector { model.inputModality = .pointer })
  }
}
