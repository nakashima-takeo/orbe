import SwiftUI

/// chrome（StatusRow・パレット・EditorPane・Onboarding 等の SwiftUI 面）へ「現在の UI 言語」を届ける
/// 観測可能ホルダー。chrome は複数の独立した `NSHostingView` に跨るため、モデル毎の糸通しでなく単一の
/// Environment で配る（`ChromeTranslucency`・`AgentIconResolver` と同型）。`language` を書き替えると
/// `@Observable` が全 root を再描画し、UI 全体が即時に切り替わる（再起動不要）。所有は `WindowController`。
@Observable final class LocalizationStore {
  /// 現在の UI 言語。設定パレットの言語行がここへ代入すると chrome 全体が再描画で切り替わる。
  var language: Language

  init(language: Language) {
    self.language = language
  }

  /// 型付きキーを現在言語の文言へ引く。網羅（table が全 `L10nKey` を持つこと）は `L10nCompletenessTests` が保証する。
  func string(_ key: L10nKey) -> String {
    L10n.string(key, language)
  }

  /// 位置引数付き書式テンプレート（`%@`/`%lld`・必要なら `%1$@` の明示位置指定）を現在言語で埋める。
  /// 日英で語順が食い違うケースは各言語のテンプレート内で順序を持つ。
  func format(_ key: L10nKey, _ args: CVarArg...) -> String {
    String(format: string(key), arguments: args)
  }

  /// 複数形。日本語は助数詞で単複不変（one/other は同一文言）、英語だけ count==1 で `one` を選ぶ。
  /// テンプレートは件数 `%lld` を 1 つ取る。
  func plural(_ count: Int, one: L10nKey, other: L10nKey) -> String {
    format(count == 1 ? one : other, count)
  }
}

private struct LocalizationKey: EnvironmentKey {
  /// 未注入（preview・浮遊 popup 等）は OS 言語追従の既定で描く。
  static let defaultValue = LocalizationStore(language: .systemDefault)
}

extension EnvironmentValues {
  /// chrome 各面が現在言語を読むための Environment 窓口。`WindowController` が各 root へ注入する。
  var localization: LocalizationStore {
    get { self[LocalizationKey.self] }
    set { self[LocalizationKey.self] = newValue }
  }
}
