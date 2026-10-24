import Foundation

/// 依頼の欄の入力例。今あるノードの行き先で言えるものだけを置き、行き先を足すときはここを差し替える。先頭は欄のプレースホルダの
/// 例にも使う。
enum BoardAutomationExamples {
  static let all: [L10nKey] = [
    .boardExampleSlack, .boardExampleReviewDigest, .boardExampleDailyNote,
  ]

  static func placeholder(_ l10n: LocalizationStore) -> String {
    l10n.format(.boardAskPlaceholder, l10n.string(all[0]))
  }
}
