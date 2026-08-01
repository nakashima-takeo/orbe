import Foundation

/// UI 言語の値型（日本語 / 英語の 2 言語）。`app-state.json` の `preferredLanguage` に rawValue で永続する。
/// **プロセスの `AppleLanguages`/ロケールには一切触れない**（`preferredLanguages` は読むだけ）。端末の
/// CJK 字形は `font-codepoint-map` が locale 非依存で固定しており、UI 言語切替はその字形に影響しない。
enum Language: String, CaseIterable, Sendable {
  case ja
  case en

  /// OS 言語追従の既定。`Locale.preferredLanguages.first` が "ja*" なら `.ja`、他は `.en`。
  static var systemDefault: Language {
    resolve(preferred: Locale.preferredLanguages.first)
  }

  /// OS 言語コードを UI 言語へ写す純関数（環境読取から分離した分類規則）。`"ja*"` は `.ja`、他・nil は `.en`。
  static func resolve(preferred code: String?) -> Language {
    (code ?? "en").hasPrefix("ja") ? .ja : .en
  }

  /// 言語選択 UI（初回カード・設定ドリルイン）に出す自称ラベル。各言語で自言語名を名乗る。
  var displayName: String {
    switch self {
    case .ja: return "日本語"
    case .en: return "English"
    }
  }

  /// 日付整形用のロケール（アップデートの日時表示などが使う）。言語追加時に case 網羅を強制する。
  var dateLocale: Locale {
    switch self {
    case .ja: return Locale(identifier: "ja_JP")
    case .en: return Locale(identifier: "en_US")
    }
  }
}
