import AppKit
import OrbeSessionLog

/// 制御チャネルのセッション復元（`restore_sessions`）。
extension WindowController {
  /// 各 id について、ログの最後のイベントを引き（無ければ `unknown`）、今 Orbe にその同一性のタブ
  /// （live / 休眠）があれば `already-present`、無ければログの workspace（rootPath で照合。無ければ
  /// ログの名前・rootPath で末尾に作る。アクティブ化しない）に休眠チケットを足して `restored`（位置は
  /// 新規タブと同じ規則——同じ worktree の連の右端、無ければ末尾）。
  /// 冪等で、部分成功は成功。復元したタブは選択も前面化もしない——起床は mount 規律に従う（アクティブ
  /// workspace に足した分は次の選択で他の未 mount タブと順次、背景 workspace の分はそのアクティブ化で）。
  func controlRestoreSessions(sessionIds: [String]) -> Result<Any, ControlError> {
    var present = store.presentSessionIds
    let results: [[String: Any]] = sessionIds.map { id in
      guard let last = sessionLog.lastEvent(sessionId: id) else {
        return ["sessionId": id, "status": "unknown"]
      }
      guard !present.contains(id) else { return ["sessionId": id, "status": "already-present"] }
      let index =
        workspaces.firstIndex { $0.rootPath == last.workspace.rootPath }
        ?? store.appendWorkspace(name: last.workspace.name, rootPath: last.workspace.rootPath)
      let restored = restoreDormantTab(
        TabState(
          cwd: last.cwd,
          agent: AgentSession(command: last.agent.command, sessionId: last.agent.sessionId),
          explicitTitle: nil),
        intoWorkspaceAt: index)
      present.insert(id)  // 同一リクエスト内の重複 id は 2 枚目を already-present にする
      return [
        "sessionId": id, "status": "restored", "workspaceId": workspaces[index].id,
        "tabId": restored.tab.id,
      ]
    }
    return .success(["results": results])
  }
}
