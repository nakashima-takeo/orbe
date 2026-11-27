import Foundation

/// 内蔵ブラウザの文言分冊。本体 `L10n.table` が結合する。
extension L10n {
  static let browserTable: [L10nKey: (ja: String, en: String)] = [
    .browserBarBack: ("戻る", "Back"),
    .browserBarForward: ("進む", "Forward"),
    .browserBarReload: ("再読込 (⌘R)", "Reload (⌘R)"),
    .browserBarStop: ("読み込みを停止", "Stop loading"),
    .browserBarURLPlaceholder: ("URL を入力…", "Enter URL…"),
    .browserBarSwitchToFull: ("全面表示へ切替", "Switch to Full View"),
    .browserBarSwitchToSheet: ("右シートへ切替", "Switch to Right Sheet"),
    .browserResizeTooltip: (
      "ドラッグで幅変更（左端で全面吸着・右端で閉じる）／ダブルクリックで全面切替",
      "Drag to resize (left edge snaps full, right edge closes) · Double-click to toggle full"
    ),
    .browserSnapFull: ("全面に吸着", "Snap to Full"),
    .browserSnapClose: ("離すと閉じる", "Release to Close"),
    .browserPeekShowTerminal: ("端末を表示", "Show Terminal"),
    .browserPeekShowEditor: ("エディターを表示", "Show Editor"),
    .browserPeekShowBoard: ("ボードを表示", "Show Board"),
    .browserPeekShowWindow: ("ウィンドウを表示", "Show Window"),
    .browserEmptyTitle: ("ブラウザ", "Browser"),
    .browserEmptyLead: (
      "上の URL 欄をクリックしてページを開いてください。",
      "Click the address bar above to open a page."
    ),
    .browserEmptyShortcutClose: ("ブラウザを閉じる", "Close browser"),
    .browserEmptyShortcutReload: ("ページを再読込", "Reload page"),
    .browserDefaultSpacePersonal: ("個人", "Personal"),
    .browserDefaultSpaceWork: ("仕事", "Work"),
    .browserDefaultSpaceResearch: ("調査", "Research"),
  ]
}
