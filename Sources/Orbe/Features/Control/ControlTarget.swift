import Foundation

/// 外部やエージェントが Orbe を操作するための domain 操作（main スレッドでのみ呼ぶ）。
/// 実体は WindowController。ControlServer がリクエストを main へ hop して叩く。
protocol ControlTarget: ControlTaskTarget, ControlAutomationTarget, ControlBoardTarget {
  func controlListWorkspaces() -> [[String: Any]]
  func controlListTabs() -> [[String: Any]]
  /// 検出済みエージェント CLI を列挙する（読み取り専用）。
  /// 検出未完了なら空配列（エラーにしない）。
  func controlListAgents() -> [[String: Any]]
  func controlResolveTab(_ id: Int) -> TerminalTab?
  /// 新タブをアクティブ workspace（または指定 workspace）に開く。`selects` が偽なら選ばずに起こす。戻り値は新タブ ID。
  func controlSpawn(workspaceId: Int?, cwd: String?, command: String?, selects: Bool) -> Int?
  /// 検出済みエージェントを新タブで起こす（spawn_agent）。command 省略時は対象 workspace の
  /// 実効 default-agent を解く。未知 workspaceId は -32004・未検出 command は -32602・
  /// 検出ゼロは -32000。
  func controlSpawnAgent(command: String?, workspaceId: Int?, cwd: String?)
    -> Result<AgentLaunch, ControlError>
  /// 既存セッションを resume してエージェントを新タブで起こす（resume_agent）。
  /// 安全文字集合の外の sessionId は -32602。
  func controlResumeAgent(command: String, sessionId: String, workspaceId: Int?, cwd: String?)
    -> Result<AgentLaunch, ControlError>
  /// タブのエージェントへ text を送って Enter を押す（prompt_agent）。入力欄が空いている状態
  /// （idle / done / 報告なし）にだけ届く動詞で、working / waiting は -32000（何も送らない）、
  /// 未 mount も -32000。成功は nil。
  func controlPromptAgent(tab: TerminalTab, text: String) -> ControlError?
  /// 背景/休眠 workspace を前面化し全タブを mount する。戻り値は activate 後の
  /// activeWorkspaceId と当該 workspace のタブ ID 群。未知 id は nil（spawn と違いフォールバックしない）。
  func controlActivateWorkspace(workspaceId: Int) -> (activeWorkspaceId: Int, tabIds: [Int])?
  /// エージェント hook の状態報告を発信元タブへ適用する（report_agent）。
  func controlReportAgent(tab: TerminalTab, report: AgentHookReport)
  /// 指定タブへフォーカスする（focus_tab）。別 WS なら activate＋タブ選択も行う。未解決は -32004。
  func controlFocusTab(tabId: Int) -> Result<Any, ControlError>
  /// 指定タブ（TerminalTab.id）を閉じる（close_tab）。カスケードは GUI（Cmd+W）と一致。未解決は -32004。
  func controlCloseTab(tabId: Int) -> Result<Any, ControlError>
  /// 指定タブの連のエディターでファイルを開き、エディター面を見せてそのタブへフォーカスする（open_file）。
  /// 未解決は -32004、開けない（読めない・UTF-8 でない・Metal の装置が無くテキスト面を作れない）は -32000。
  func controlOpenFile(tabId: Int, path: String) -> Result<Any, ControlError>
  /// 指定タブの連のエディターで diff を開き、エディター面を見せてそのタブへフォーカスする（open_diff）。未解決は -32004、
  /// git 管理外のパス・Metal の装置が無くテキスト面を作れないは -32000。
  func controlOpenDiff(tabId: Int, path: String, kind: EditorDiff.Kind) -> Result<Any, ControlError>
  /// 全設定項目の実効値・由来 scope・型・値域（domain）を列挙する（config CLI 用・読み取り専用）。
  /// workspaceId 指定でその WS の上書きを重ねる（未指定はアクティブ WS）。未知 id は -32004。
  func controlConfigList(workspaceId: Int?) -> Result<Any, ControlError>
  /// 設定 1 項目を global / workspace スコープへ設定しライブ反映する（config CLI 用）。
  /// workspaceId 指定で対象 WS（未指定はアクティブ WS）の上書きへ書く。未知 id は -32004。
  func controlConfigSet(key: String, value: Any, scope: String, workspaceId: Int?)
    -> Result<Any, ControlError>
  /// workspace を新規作成しアクティブ化する。戻り値は新 workspace の id・name・rootPath。
  func controlCreateWorkspace(name: String, rootPath: String?) -> Result<Any, ControlError>
  /// workspace を改名する（id 未発見 -32004・name 空 -32602）。
  func controlRenameWorkspace(workspaceId: Int, name: String) -> Result<Any, ControlError>
  /// workspace の rootPath を変更する（id 未発見 -32004・Home -32000・rootPath 空 -32602）。
  func controlSetWorkspaceRoot(workspaceId: Int, rootPath: String) -> Result<Any, ControlError>
  /// workspace を削除する（id 未発見 -32004・Home と最後の通常 workspace は削除不可 -32000）。
  func controlRemoveWorkspace(workspaceId: Int) -> Result<Any, ControlError>
  /// 閉じたセッションを休眠チケットとして戻す（restore_sessions）。id ごとの status
  /// （restored / already-present / unknown）を返す。窓は onWindow が保証する。
  func controlRestoreSessions(sessionIds: [String]) -> Result<Any, ControlError>
}

struct ControlError: Error {
  let code: Int
  let message: String
}
