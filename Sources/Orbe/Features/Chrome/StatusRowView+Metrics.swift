import SwiftUI

/// タブ行の投影値の取り出し（表示タイトル・状態グリフ・同一性）と寸法計算（幅・自然幅）。
/// 描画（`StatusRowView`）から分離する。
/// 幅計測の基底は常にタブタイトル実効フォント（描画 `DSTab` と同じ resolver）でズレを避ける。
extension StatusRowView {
  /// 描くセグメント列。controller が流した `model.segments` が titles を覆っていればそれ、
  /// 流し込まないホスト（gallery 等）では全タブ単独。
  var segments: [Range<Int>] {
    let n = model.titles.count
    let covers = model.segments.first?.lowerBound == 0 && model.segments.last?.upperBound == n
    return covers ? model.segments : StatusTabLayout.singletons(count: n)
  }

  /// shrink 幅（純関数 `StatusTabLayout`）を出したうえで、編集タブの幅だけ編集用の下限で上書きする。
  /// 純関数のシグネチャは変えず、上書きは View 側に閉じる（溢れは横 ScrollView が吸収）。
  func tabWidths(available: CGFloat) -> [CGFloat] {
    var widths = StatusTabLayout.widths(
      naturals: model.titles.indices.map(naturalWidth(index:)), segments: segments,
      available: available)
    if let e = model.editingIndex, widths.indices.contains(e) {
      widths[e] = min(Chrome.tabMaxWidth, max(editingNaturalWidth(), Chrome.tabEditFloor))
    }
    return widths
  }

  func displayTitle(_ i: Int) -> String {
    let t = model.titles[i]
    return t.isEmpty ? "Terminal" : t
  }

  func stateGlyph(_ i: Int) -> AgentStateIcon.Kind? {
    model.glyphs.indices.contains(i) ? model.glyphs[i] : nil
  }

  /// タブ `i` の同一性（`tabIds` を流し込まないホスト＝gallery 等では nil）。
  func tabId(_ i: Int) -> Int? {
    model.tabIds.indices.contains(i) ? model.tabIds[i] : nil
  }

  /// タブの自然幅（タイトル＋状態グリフ＋左右余白）。shrink-to-fit の上限（cap は widths 側）。
  func naturalWidth(index i: Int) -> CGFloat {
    naturalWidth(text: displayTitle(i), hasGlyph: stateGlyph(i) != nil)
  }

  /// 編集タブの基底テキスト。入力があればそれ、空なら戻り先の派生名（field 幅とズレないように）。
  func editingMeasureText() -> String {
    model.editingText.isEmpty ? model.editingPlaceholder : model.editingText
  }

  /// 編集タブの自然幅（`editingText`／派生名を基底に測る。上書き前の cap 値）。
  func editingNaturalWidth() -> CGFloat {
    naturalWidth(
      text: editingMeasureText(), hasGlyph: model.editingIndex.flatMap(stateGlyph) != nil)
  }

  /// 自然幅の共通式（タイトル＋状態グリフ＋左右余白）。基底は常にタブタイトル実効フォント（描画
  /// `DSTab` と同じ resolver）。インジケータ幅は DSTab の描画に揃える: グリフ 12pt＋gap 6、無しは 0。
  /// 左右 padding 8×2。通常タブと編集タブで唯一の寸法源とし、片方だけズレるのを防ぐ。
  private func naturalWidth(text: String, hasGlyph: Bool) -> CGFloat {
    let textW = fontResolver.width(text, base: fontResolver.tabTitleFont)
    let indicatorW: CGFloat = hasGlyph ? 12 + Theme.Space.note : 0
    return ceil(textW) + indicatorW + Theme.Space.step * 2
  }
}
