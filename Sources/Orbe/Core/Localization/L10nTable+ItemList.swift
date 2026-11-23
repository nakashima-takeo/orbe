import Foundation

/// エディター面の上のバーの今の項目のボタンと、一覧の器（開いているファイルの一覧）の文言分冊。本体 `L10n.table` が結合する。
extension L10n {
  static let itemListTable: [L10nKey: (ja: String, en: String)] = [
    .editorBarOpenFiles: ("開いているファイルの一覧", "Open Files"),
    .editorItemUnsaved: ("未保存", "Unsaved"),
    .editorItemDiskChanged: ("ディスク上で変更されています", "Changed on Disk"),
    .editorItemListSwitch: ("切替", "Switch"),
    .editorItemListDetail: ("詳細", "Details"),
    .editorItemListRun: ("実行", "Run"),
    .editorItemListBack: ("戻る", "Back"),
    .editorItemListClose: ("閉じる", "Close"),
    .editorOpenFilesTitle: ("開いているファイル", "Open Files"),
    .editorOpenFilesCurrent: ("現在", "Current"),
    .editorOpenFilesPreview: ("プレビュー", "Preview"),
    .editorOpenFilesKeepOpen: ("開いたままにする", "Keep Open"),
    .editorOpenFilesCloseFile: ("ファイルを閉じる", "Close File"),
  ]
}
