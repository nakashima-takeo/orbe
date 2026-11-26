import SwiftUI

/// Changes の画面の、上のバーの部品。部品ごとに寄せる側と譲る順を名乗る（→ `editorBarPart`）。
extension EditorBarRoot {
  /// 今の項目の後ろに、左寄せで並ぶ部品。
  @ViewBuilder var changesMiddle: some View {}

  /// 右端に並ぶ部品。
  @ViewBuilder var changesTrailing: some View {}
}
