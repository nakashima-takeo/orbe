import AppKit
import OrbeSessionLog

/// 同一性の寿命の記録と、⇧⌘T「閉じたエージェント」パレットの提示・追従・復元。
///
/// 記録: タブは「何が始まり／終わったか」だけを決め、所属 workspace（名前・rootPath）はここで引いて
/// `SessionEvent` に組む——タブは上位を型として参照しない（`layout.md` の一方向参照）。
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
      kind = .closed(origin: origin, reason: reason)
      agent = identity
    }
    sessionLog.record(
      SessionEvent(
        ts: Date(), kind: kind,
        workspace: SessionEvent.Workspace(name: ws.name, rootPath: ws.rootPath),
        cwd: tab.cwd, agent: agent))
    refreshChrome()  // パレット表示中の追従を coalesce に乗せる
  }

  // MARK: - ⇧⌘T

  /// ⇧⌘T。アクティブ workspace で閉じたまま戻っていないエージェントの一覧を開く（既に開いていれば
  /// 再フォーカス）。閉じ側は Esc / scrim（`dismissPalette`）。0 タブでも開く（`availableWithoutTabs`）。
  func showClosedAgentsPalette() {
    if model.overlay == .closedAgentsPalette {
      model.closedAgentsPalette?.focus()
      return
    }
    let p = ClosedAgentsPaletteModel(localization: localization)
    p.onDismiss = { [weak self] in self?.dismissPalette() }
    p.onRestore = { [weak self] items in self?.restoreClosedAgents(items) }
    p.setGroups(currentClosedAgentGroups())
    model.closedAgentsPalette = p
    model.overlay = .closedAgentsPalette
    p.focus()
    reconfirmFocusNextTick()
  }

  /// `flushChrome` から呼ぶ追従（既存 coalesce に相乗り）。表示中だけ一覧を組み直す。
  func refreshClosedAgentsPalette() {
    guard model.overlay == .closedAgentsPalette else { return }
    model.closedAgentsPalette?.setGroups(currentClosedAgentGroups())
  }

  private func currentClosedAgentGroups() -> [ClosedAgentGroup] {
    ClosedAgentsSnapshot.groups(
      events: sessionLog.events,
      present: ClosedAgentsSnapshot.presentSessionIds(of: workspaces),
      rootPath: current.rootPath)
  }

  /// 休眠チケットとしてアクティブ workspace の末尾に足し、復元した先頭のタブを選択して起こす。
  /// 残りは `select` に続く既存の分割 mount（`scheduleHiddenMounts`）で順次起床する——起動復元で
  /// アクティブ workspace の全タブが順次 resume されるのと同じで、mount 規律に例外は作らない。
  private func restoreClosedAgents(_ items: [ClosedAgentItem]) {
    let index = activeWorkspace
    var first: Int?
    for item in items {
      restoreDormantTab(
        TabState(
          cwd: item.cwd,
          agent: AgentSession(command: item.command, sessionId: item.sessionId),
          explicitTitle: nil),
        intoWorkspaceAt: index)
      if first == nil { first = current.tabs.count - 1 }
    }
    if let first { select(first) }
    dismissPalette()  // dismiss の focusActiveTab が新しい active＝復元した先頭へ当たる
  }
}
