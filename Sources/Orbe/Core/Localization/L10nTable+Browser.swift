import Foundation

/// 内蔵ブラウザの文言分冊。本体 `L10n.table` が結合する。
extension L10n {
  static let browserTable: [L10nKey: (ja: String, en: String)] = [
    .browserBarToggleSidebar: ("サイドバーを開閉 (⌘S)", "Toggle Sidebar (⌘S)"),
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
    .browserDefaultSpacePersonal: ("個人", "Personal"),
    .browserDefaultSpaceWork: ("仕事", "Work"),
    .browserDefaultSpaceResearch: ("調査", "Research"),
    .browserSidebarLocalTag: ("ローカル", "Local"),
    .browserSidebarLocalFallback: ("ローカル", "Local"),
    .browserSidebarProfileTooltip: ("プロファイルと MCP 読み取り権限", "Profile and MCP read access"),
    .browserSidebarSectionPinned: ("PINNED", "PINNED"),
    .browserSidebarSectionToday: ("TODAY", "TODAY"),
    .browserSidebarClearToday: ("Clear · 12h", "Clear · 12h"),
    .browserSidebarClearTodayTooltip: ("TODAY タブを一括整理", "Clear TODAY tabs"),
    .browserSidebarNewTab: ("新しいタブ", "New Tab"),
    .browserSidebarCloseTabTooltip: ("タブを閉じる", "Close tab"),
    .browserSidebarAddSpaceTooltip: ("自由スペースを追加", "Add space"),
    .browserSidebarLocalTooltip: ("ローカルスペース（%@）", "Local space (%@)"),
    .browserSidebarSpaceTooltip: ("%@（%@）", "%@ (%@)"),
    .browserMenuPin: ("ピン留めする (PINNED)", "Pin tab (PINNED)"),
    .browserMenuAddFavorite: ("お気に入りに追加 (Favorites)", "Add to Favorites"),
    .browserMenuUnpin: ("ピン留めを外す (TODAY へ戻す)", "Unpin (move to TODAY)"),
    .browserMenuMoveToPinned: ("PINNED へ移す", "Move to PINNED"),
    .browserMenuMoveToToday: ("TODAY へ戻す", "Move to TODAY"),
    .browserMenuCloseTab: ("タブを閉じる", "Close Tab"),
    .browserMenuEditSpace: ("スペースを編集…", "Edit Space…"),
    .browserMenuDeleteSpace: ("スペースを削除…", "Delete Space…"),
    .browserProfileHeading: ("%@ プロファイル", "%@ Profile"),
    .browserProfileCookieNote: (
      "プロファイルごとに Cookie と保存データを分離", "Isolates cookies and storage per profile"
    ),
    .browserProfileMCPAllowed: ("MCP からの読み取りを許可", "Allow MCP read access"),
    .browserProfileMCPBlocked: ("MCP から非公開（遮断）", "Private from MCP (blocked)"),
    .browserProfileMCPAllowedNote: (
      "ページ内容・コンソール・スクリーンショットを読み取り可能",
      "Allows reading page content, console, and screenshots"
    ),
    .browserProfileMCPBlockedNote: (
      "エージェントからの読み取りを遮断します", "Blocks reading from CLI agents"
    ),
    .browserProfileSectionSpace: ("このスペースのプロファイル", "Profile for this space"),
    .browserProfileCreateAction: ("新しいプロファイルを作成…", "Create new profile…"),
    .browserProfileEditTooltip: ("プロファイルを編集", "Edit profile"),
    .browserProfileCreateTitle: ("新しいプロファイル", "New Profile"),
    .browserProfileEditTitle: ("プロファイルを編集", "Edit Profile"),
    .browserProfileNameLabel: ("名前", "Name"),
    .browserProfileNamePlaceholder: ("プロファイル名", "Profile name"),
    .browserProfileColorLabel: ("色", "Color"),
    .browserProfileDeleteAction: ("このプロファイルを削除…", "Delete this profile…"),
    .browserProfileDeleteTitle: ("プロファイルを削除", "Delete Profile"),
    .browserProfileDeleteMessage: (
      "「%@」を削除します。このプロファイルの Cookie と保存データは破棄されます。",
      "Delete \"%@\"? Cookies and storage for this profile will be removed."
    ),
    .browserProfileReassignLabel: ("付け替え先プロファイル", "Reassign spaces to"),
    .browserProfileReassignMCPExposeWarning: (
      "非公開プロファイルのスペースが MCP 公開プロファイルへ移行します。",
      "Spaces from this private profile will become readable via MCP."
    ),
    .browserSpaceCreateTitle: ("新しいスペース", "New Space"),
    .browserSpaceEditTitle: ("スペースを編集", "Edit Space"),
    .browserSpaceNameLabel: ("名前", "Name"),
    .browserSpaceNamePlaceholder: ("スペース名", "Space name"),
    .browserSpaceIconLabel: ("アイコン", "Icon"),
    .browserSpaceProfileLabel: ("プロファイル", "Profile"),
    .browserSpaceDeleteAction: ("スペースを削除…", "Delete space…"),
    .browserSpaceDeleteTitle: ("スペースを削除", "Delete Space"),
    .browserSpaceDeleteMessageOne: (
      "「%@」と配下の %lld 件のタブを削除します。",
      "Delete \"%@\" and its %lld tab?"
    ),
    .browserSpaceDeleteMessageOther: (
      "「%@」と配下の %lld 件のタブを削除します。",
      "Delete \"%@\" and its %lld tabs?"
    ),
    .browserActionSave: ("保存", "Save"),
    .browserActionCreate: ("作成", "Create"),
    .browserActionCancel: ("キャンセル", "Cancel"),
    .browserActionDelete: ("削除する", "Delete"),
    .browserActionBack: ("戻る", "Back"),
    .browserNewTabTitle: ("新しいタブ", "New Tab"),
    .browserNewTabQuickAccess: ("クイックアクセス", "Quick Access"),
    .browserNewTabRecentlyClosed: ("最近閉じたタブ", "Recently Closed"),
  ]
}
