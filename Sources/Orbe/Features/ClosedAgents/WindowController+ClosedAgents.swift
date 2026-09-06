import AppKit

/// ⇧⌘T「閉じたエージェント」パレットの提示・追従・復元。
extension WindowController {
  /// ⇧⌘T。アクティブ workspace で閉じたまま戻っていないエージェントの一覧を開く（既に開いていれば
  /// 再フォーカス）。閉じ側は Esc / scrim（`dismissPalette`）。0 タブでも開く（`availableWithoutTabs`）。
  func showClosedAgentsPalette() {
    if model.overlay == .closedAgentsPalette {
      model.closedAgentsPalette?.focus()
      return
    }
    let p = ClosedAgentsPaletteModel(localization: localization)
    p.onDismiss = { [weak self] in self?.dismissPalette() }
    p.onRestore = { [weak self] item in self?.restoreClosedAgent(item) }
    p.setItems(currentClosedAgentItems())
    model.closedAgentsPalette = p
    model.overlay = .closedAgentsPalette
    p.focus()
    reconfirmFocusNextTick()
  }

  /// `flushChrome` から呼ぶ追従（既存 coalesce に相乗り）。表示中だけ一覧を組み直す。
  func refreshClosedAgentsPalette() {
    guard model.overlay == .closedAgentsPalette else { return }
    model.closedAgentsPalette?.setItems(currentClosedAgentItems())
  }

  private func currentClosedAgentItems() -> [ClosedAgentItem] {
    ClosedAgentsSnapshot.items(
      events: sessionLog.events,
      present: store.presentSessionIds,
      rootPath: current.rootPath)
  }

  /// 選んだ 1 件を休眠チケットとしてアクティブ workspace の末尾に足し、パレットを閉じてそのタブを
  /// 選択して起こす。1 度に戻すのは 1 件——多数を戻すのは orb / MCP の `restore_sessions` の役割。
  private func restoreClosedAgent(_ item: ClosedAgentItem) {
    restoreDormantTab(
      TabState(
        cwd: item.cwd,
        agent: AgentSession(command: item.command, sessionId: item.sessionId),
        explicitTitle: nil),
      intoWorkspaceAt: activeWorkspace)
    select(current.tabs.count - 1)
    dismissPalette()  // dismiss の focusActiveTab が新しい active＝復元したタブへ当たる
  }
}
