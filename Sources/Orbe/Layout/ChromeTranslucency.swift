import SwiftUI

/// chrome（StatusRow・パレット・EditorPane 等の SwiftUI 面）へ「背景の不透明度／ブラー」を届ける観測可能ホルダー。
/// chrome は複数の独立した `NSHostingView` に跨るため、モデル毎の糸通しでなく単一の Environment で配る。
/// 値の材料は `WindowController.syncWindowOpacity` と同一（実効設定の backgroundOpacity/backgroundBlur）で、
/// `update` を同一 tick で呼んで揃える。所有は `WindowController`。
@Observable final class ChromeTranslucency {
  /// chrome 面が bgBase backstop を薄める実効係数。不透明時 1.0・透過時 percent/100。
  /// 端末面（libghostty `background-opacity`）と同じ濃度の veil を chrome へ与える。
  private(set) var effectiveOpacity: CGFloat
  /// 透過中か（percent<100 かつ非フルスクリーン）。追加 base（StatusRow）の要否ゲート。
  private(set) var translucent: Bool
  /// すりガラス希望か（透過時のみ有効・不透明時は false）。GlassPanel の VisualEffectView 要否。
  private(set) var blur: Bool

  init(effectiveOpacity: CGFloat = 1, translucent: Bool = false, blur: Bool = false) {
    self.effectiveOpacity = effectiveOpacity
    self.translucent = translucent
    self.blur = blur
  }

  /// 透過状態の値（純関数 `resolve` の結果・ホルダーへ反映する）。
  struct State: Equatable {
    var effectiveOpacity: CGFloat
    var translucent: Bool
    var blur: Bool
  }

  /// 設定値から透過状態を導く純関数（`syncWindowOpacity` と同じ材料・テスト可能）。
  /// 不透明（100%・フルスクリーン）なら effectiveOpacity=1・translucent=false・blur=false へ畳む
  /// （libghostty も opaque では blur を早期 return するため、chrome も同じゲートを共有する）。
  static func resolve(percent: Int, isFullScreen: Bool, blur: Bool) -> State {
    let translucent = WindowController.shouldBeTranslucent(
      percent: percent, isFullScreen: isFullScreen)
    return State(
      effectiveOpacity: translucent ? CGFloat(percent) / 100 : 1, translucent: translucent,
      blur: translucent ? blur : false)
  }

  /// 実効設定から現在値を再計算する（`syncWindowOpacity` と同一 tick で呼ぶ）。
  func update(percent: Int, isFullScreen: Bool, blur: Bool) {
    let s = Self.resolve(percent: percent, isFullScreen: isFullScreen, blur: blur)
    effectiveOpacity = s.effectiveOpacity
    translucent = s.translucent
    self.blur = s.blur
  }

  /// 既存の不透明 bgBase backstop を置換する塗り（不透明時=不透明 bgBase・透過時=effectiveOpacity でスケール）。
  /// EditorPane 等、元々 bgBase の不透明地に載っていた面が使う。
  var baseFill: Color { Color.theme.bgBase.opacity(effectiveOpacity) }

  /// 透過時のみ足す追加 base（不透明時は clear＝現行の透明を維持し glow を透かす）。
  /// 上段が元来透明な StatusRow が、透過時だけ端末と同濃度の veil を敷くために使う。
  var additiveBase: Color { Color.theme.bgBase.opacity(translucent ? effectiveOpacity : 0) }
}

private struct ChromeTranslucencyKey: EnvironmentKey {
  /// 未注入（preview・浮遊 popup 等）は不透明既定＝現行描画。
  static let defaultValue = ChromeTranslucency()
}

extension EnvironmentValues {
  /// chrome 各面が背景透過・ブラーを読むための Environment 窓口。`WindowController` が各 root へ注入する。
  var chromeTranslucency: ChromeTranslucency {
    get { self[ChromeTranslucencyKey.self] }
    set { self[ChromeTranslucencyKey.self] = newValue }
  }
}
