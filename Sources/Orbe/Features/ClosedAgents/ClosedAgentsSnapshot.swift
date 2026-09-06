import Foundation
import OrbeSessionLog

/// ⇧⌘T 一覧の 1 件（値型 snapshot）。復元に要る同一性と cwd、行に出す閉じた時点のタイトル・時刻・終わり方。
struct ClosedAgentItem: Equatable {
  let sessionId: String
  let command: String
  let cwd: String
  /// 閉じた時点の workspace の rootPath（行の cwd を root 相対で出す基点）。
  let rootPath: String
  /// 閉じた時点のタブの表示タイトル（ログの `title`）。無ければ行はタブバーの空タイトルと同じ既定語で出す。
  let title: String?
  let closedAt: Date
  let origin: SessionEvent.CloseOrigin
}

/// ログ → ⇧⌘T 一覧の導出（pure）。対象はアクティブ workspace（`rootPath` 一致）で閉じたまま戻っていない
/// 同一性だけ。群は持たない——同じ事故で落ちた連続行はそのまま並ぶ（群を扱うのは orb / MCP）。
enum ClosedAgentsSnapshot {
  /// 新しい順（ファイル順の逆）。
  static func items(events: [SessionEvent], present: Set<String>, rootPath: String)
    -> [ClosedAgentItem]
  {
    SessionLogQuery.closedNotPresent(events: events, present: present)
      .reversed()
      .filter { $0.workspace.rootPath == rootPath }
      .compactMap(item)
  }

  /// 今 Orbe に居る同一性（全 workspace・live / 休眠を問わない）。`list_tabs` の `agentSessionId` と
  /// 同じ読み口なので、CLI 側の導出と一致する。
  static func presentSessionIds(of workspaces: [Workspace]) -> Set<String> {
    Set(workspaces.flatMap { ws in ws.tabs.compactMap { $0.agentSlot.session?.sessionId } })
  }

  private static func item(_ event: SessionEvent) -> ClosedAgentItem? {
    guard let origin = event.closeOrigin else { return nil }
    return ClosedAgentItem(
      sessionId: event.sessionId, command: event.agent.command, cwd: event.cwd,
      rootPath: event.workspace.rootPath, title: event.closeTitle, closedAt: event.ts,
      origin: origin)
  }
}
