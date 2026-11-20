import Foundation

/// 外部やエージェントが Orbe を操作するための domain 操作（main でのみ呼ぶ）。実体は WindowController で、ControlServer が main へ hop して叩く。
protocol ControlTarget: ControlTaskTarget, ControlAutomationTarget, ControlBoardTarget {
  func controlListWorkspaces() -> [[String: Any]]
  /// タブを列挙する。workspaceId 指定でその workspace のタブだけ。未知 id は -32004。
  func controlListTabs(workspaceId: UUID?) -> Result<[[String: Any]], ControlError>
  /// 検出済みエージェント CLI を列挙する（読み取り専用）。検出未完了なら空配列（エラーにしない）。
  func controlListAgents() -> [[String: Any]]
  func controlResolveTab(_ id: Int) -> TerminalTab?
  /// 新タブをアクティブ（または指定の）workspace に開き、新タブ ID を返す。`selects` が偽なら選ばずに起こす。未知 id は -32004。
  func controlSpawn(workspaceId: UUID?, cwd: String?, command: String?, selects: Bool)
    -> Result<Int, ControlError>
  /// 検出済みエージェントを新タブで起こす（spawn_agent）。command 省略時は対象 workspace の実効 default-agent を解く。
  /// 未知 workspaceId は -32004・未検出 command は -32602・検出ゼロは -32000。
  func controlSpawnAgent(command: String?, workspaceId: UUID?, cwd: String?)
    -> Result<AgentLaunch, ControlError>
  /// 既存セッションを resume してエージェントを新タブで起こす（resume_agent）。安全文字集合の外の sessionId は -32602。
  func controlResumeAgent(command: String, sessionId: String, workspaceId: UUID?, cwd: String?)
    -> Result<AgentLaunch, ControlError>
  /// タブのエージェントへ text を送って Enter を押す（prompt_agent）。入力欄が空いている状態
  /// （idle / done / 報告なし）にだけ届く動詞で、working / waiting は -32000（何も送らない）、
  /// 未 mount も -32000。成功は nil。
  func controlPromptAgent(tab: TerminalTab, text: String) -> ControlError?
  /// 背景/休眠 workspace を前面化し全タブを mount する。戻り値は activeWorkspaceId とそのタブ ID 群。未知 id は nil。
  func controlActivateWorkspace(workspaceId: UUID) -> (activeWorkspaceId: UUID, tabIds: [Int])?
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
  func controlConfigList(workspaceId: UUID?) -> Result<Any, ControlError>
  /// 設定 1 項目を global / workspace スコープへ設定しライブ反映する（config CLI 用）。
  /// workspaceId 指定で対象 WS（未指定はアクティブ WS）の上書きへ書く。未知 id は -32004、global に添えると -32602。
  func controlConfigSet(key: String, value: Any, scope: String, workspaceId: UUID?)
    -> Result<Any, ControlError>
  /// workspace を新規作成しアクティブ化する。戻り値は新 workspace の id・name・rootPath。
  func controlCreateWorkspace(name: String, rootPath: String?) -> Result<Any, ControlError>
  /// workspace を改名する（id 未発見 -32004・name 空 -32602）。
  func controlRenameWorkspace(workspaceId: UUID, name: String) -> Result<Any, ControlError>
  /// workspace の rootPath を変更する（id 未発見 -32004・Home -32000・rootPath 空 -32602）。
  func controlSetWorkspaceRoot(workspaceId: UUID, rootPath: String) -> Result<Any, ControlError>
  /// workspace を削除する（id 未発見 -32004・Home と最後の通常 workspace は削除不可 -32000）。
  func controlRemoveWorkspace(workspaceId: UUID) -> Result<Any, ControlError>
  /// 閉じたセッションを休眠チケットとして戻す（restore_sessions）。id ごとの status（restored / already-present /
  /// unknown）を返す。窓は onWindow が保証する。
  func controlRestoreSessions(sessionIds: [String]) -> Result<Any, ControlError>
}

struct ControlError: Error {
  let code: Int
  let message: String
}
