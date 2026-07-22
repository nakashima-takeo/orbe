import SwiftUI

/// オーバーレイ背後に敷く Orbe の暗幕（scrim）。全画面 `VisualEffectView` で背後をぼかし、
/// 用途別の暗幕 tint を重ねる。純視覚のみ（タップ吸収・閉じる等の挙動は
/// 呼び出し側 Overlay が持つ）。`ignoresSafeArea` も呼び出し側に委ねる（overlay 側で付与済）。
struct Scrim: View {
  enum Strength { case normal, strong }

  var strength: Strength = .strong

  var body: some View {
    ZStack {
      // 狙いの blur 半径は normal 6px / strong 8px。公開APIで半径指定できない
      // NSVisualEffectView は共通materialに留め、強度差は tint（scrim / scrimStrong）で保持する。
      VisualEffectView(material: .hudWindow)
      Color(nsColor: strength == .strong ? Theme.Color.scrimStrong : Theme.Color.scrim)
    }
  }
}
