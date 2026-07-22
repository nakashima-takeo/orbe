import AppKit
import SwiftUI

/// chrome 全域のユーザー由来文字列（タブタイトル・workspace 名・cwd・パレット行・EditorPane の
/// ファイル名/本文行等）へ、実効設定を反映したフォント割り当てを届ける観測可能ホルダー。
/// chrome は複数の独立した `NSHostingView` に跨るため、モデル毎の糸通しでなく単一の Environment で配る
/// （`AgentIconResolver` と同型）。値の材料はアクティブ workspace の実効設定（emojiFont /
/// tabTitleFontFamily）で、`applyActiveWorkspaceConfig` が外観/gui.conf と同一 tick で更新する。
/// 所有は `WindowController`。run 分割・VS16 昇格の実体は `TitleGlyphs`。
@Observable final class ChromeFontResolver {
  /// 絵文字 run に充てるフォント。既定は同梱 Noto（実効既定 noto と対称・バンドル無しは nil）。
  /// nil＝割り当てなし＝Apple Color Emoji へ委譲（apple 選択時と degrade の両方）。
  var emojiFont: NSFont? = TitleGlyphs.notoEmoji

  /// タブタイトルの実効基底フォント（描画と幅計測の両方に効く）。未設定・解決不能名は
  /// 既定の等幅システム 11pt（`Theme.Typography.chrome`）。
  var tabTitleFont: NSFont = Theme.Typography.chrome

  /// run 割り当て済みの表示用文字列（基底フォントは view 側の `.font()` が当てる）。
  func attributed(_ text: String, base: NSFont) -> AttributedString {
    TitleGlyphs.attributed(text, base: base, emoji: emojiFont)
  }

  /// `attributed` と同じ割り当てでの描画幅（タブの自然幅計算が使う）。
  func width(_ text: String, base: NSFont) -> CGFloat {
    TitleGlyphs.width(text, base: base, emoji: emojiFont)
  }

  /// 端末系グリフ/絵文字を含む文字列だけ AttributedString を組む Text ファクトリ。
  /// 含まない文字列（FileViewer 本文行の大半）は走査を早期打ち切りして素の Text のまま。
  func text(_ text: String, base: NSFont) -> Text {
    TitleGlyphs.needsAssignment(text)
      ? Text(attributed(text, base: base)) : Text(verbatim: text)
  }
}

private struct ChromeFontResolverKey: EnvironmentKey {
  /// 未注入（preview・浮遊 popup 等）は既定＝Noto 絵文字・システム等幅タブタイトル。
  static let defaultValue = ChromeFontResolver()
}

extension EnvironmentValues {
  /// chrome 各面がフォント割り当てを読む Environment 窓口。`WindowController` が各 root へ注入する。
  var chromeFontResolver: ChromeFontResolver {
    get { self[ChromeFontResolverKey.self] }
    set { self[ChromeFontResolverKey.self] = newValue }
  }
}
