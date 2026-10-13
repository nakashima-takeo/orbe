import Foundation

/// 依頼の欄の入力例。今ある出力先（タスク候補・コマンド）で言えるものだけを置き、出力先を足すときはここを差し替える。先頭は
/// 欄のプレースホルダの例にも使う。
enum BoardAutomationExamples {
  static let all: [L10nKey] = [.boardExampleSlack, .boardExampleGitHub, .boardExampleDailyNote]

  static func placeholder(_ l10n: LocalizationStore) -> String {
    l10n.format(.boardAskPlaceholder, l10n.string(all[0]))
  }
}
