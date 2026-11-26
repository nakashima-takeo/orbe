import SwiftUI

/// Files の画面の、上のバーの部品。部品ごとに寄せる側と譲る順を名乗る（→ `editorBarPart`）。
extension EditorBarRoot {
  /// 今の項目の後ろに、左寄せで並ぶ部品——ファイル内検索の欄（出している間だけ）。
  @ViewBuilder var filesMiddle: some View {
    if let model = findField.model { EditorBarFindField(model: model) }
  }

  /// 右端に並ぶ部品。
  @ViewBuilder var filesTrailing: some View {}
}
