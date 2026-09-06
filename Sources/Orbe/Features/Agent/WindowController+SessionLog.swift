import AppKit
import OrbeSessionLog

/// 同一性の寿命の記録。タブは「何が始まり／終わったか」だけを決め、所属 workspace（名前・rootPath）と
/// closed のタイトルはここで引いて `SessionEvent` に組む——タブは上位を型として参照しない（`layout.md` の
/// 一方向参照）し、派生タイトルは workspace の rootPath に依存する。
extension WindowController {
  /// `TerminalTab.onIdentityTransition` の受け口。store の口（`detach`）は配列から外す**前**に告げるので、
  /// 閉じる経路でも所属 workspace が引ける。見つからなければ書かない。
  func recordSessionEvent(_ transition: TerminalTab.IdentityTransition, of tab: TerminalTab) {
    guard let ws = workspaces.first(where: { ws in ws.tabs.contains { $0 === tab } }) else {
      return
    }
    let kind: SessionEvent.Kind
    let agent: SessionEvent.Agent
    switch transition {
    case .opened(let identity):
      kind = .opened
      agent = identity
    case .closed(let identity, let origin, let reason):
      kind = .closed(
        origin: origin, reason: reason, title: tab.displayTitle(workspaceRoot: ws.rootPath))
      agent = identity
    }
    sessionLog.record(
      SessionEvent(
        ts: Date(), kind: kind,
        workspace: SessionEvent.Workspace(name: ws.name, rootPath: ws.rootPath),
        cwd: tab.cwd, agent: agent))
    refreshChrome()  // パレット表示中の追従を coalesce に乗せる
  }
}
