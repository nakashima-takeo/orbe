import Foundation
import OrbeSessionLog

/// ⇧⌘T 一覧の 1 件（値型 snapshot）。復元に要る同一性と cwd、行に出す閉じた時刻・終わり方・理由。
struct ClosedAgentItem: Equatable {
  let sessionId: String
  let command: String
  let cwd: String
  /// 閉じた時点の workspace の rootPath（行の cwd を root 相対で出す基点）。
  let rootPath: String
  let closedAt: Date
  let origin: SessionEvent.CloseOrigin
  let reason: String?
}

/// 同じ事故で閉じた群。`atKey` は群の同一性（`SessionBurst.atISO`）で、一部を復元しても動かない。
struct ClosedAgentGroup: Equatable {
  let at: Date
  let atKey: String
  let origin: SessionEvent.CloseOrigin
  /// 新しい順。
  let items: [ClosedAgentItem]
}

/// ログ → ⇧⌘T 一覧の導出（pure）。対象はアクティブ workspace（`rootPath` 一致）で閉じたまま戻っていない
/// 同一性だけ。群の切り方は orb `session closed` と同じ `SessionLogQuery.closedGroups`。
enum ClosedAgentsSnapshot {
  /// 群も群内も新しい順。他 workspace のメンバーを落として空になった群は出さない。
  static func groups(events: [SessionEvent], present: Set<String>, rootPath: String)
    -> [ClosedAgentGroup]
  {
    SessionLogQuery.closedGroups(events: events, present: present)
      .reversed()
      .compactMap { burst in
        let items = burst.sessions.reversed()
          .filter { $0.workspace.rootPath == rootPath }
          .compactMap(item)
        guard !items.isEmpty else { return nil }
        return ClosedAgentGroup(
          at: burst.at, atKey: burst.atISO, origin: burst.origin, items: items)
      }
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
      rootPath: event.workspace.rootPath, closedAt: event.ts, origin: origin,
      reason: event.closeReason)
  }
}
