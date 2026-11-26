import Foundation

/// エディター面の左の列のエクスプローラー（上の行のツール・絞り込みの欄と文の行）の文言分冊。本体 `L10n.table` が結合する。
extension L10n {
  static let explorerTable: [L10nKey: (ja: String, en: String)] = [
    .editorNewFile: ("新規ファイル", "New File"),
    .editorNewFolder: ("新規フォルダ", "New Folder"),
    .editorCollapseAll: ("すべて折りたたむ", "Collapse All"),
    .editorExpandAll: ("すべて展開", "Expand All"),
    .editorFilterPlaceholder: ("ファイルを絞り込む", "Filter Files"),
    .editorFilterNoMatches: ("一致するファイルがありません。", "No matching files."),
    .editorFilterTooManyMatches: (
      "一致が多いため、一部だけを表示しています。", "Too many matches. Only some of them are shown."
    ),
    .editorFilterTooManyFiles: (
      "ファイルが多いため、一部だけを対象にしています。", "Too many files. Only some of them are searched."
    ),
    .editorFilterListFailed: ("ファイルの一覧を取得できませんでした。", "Couldn’t list the files."),
  ]
}
