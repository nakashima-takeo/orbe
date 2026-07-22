import AppKit

/// window コマンドのディスパッチ（surface 経路・window レベル経路の共通実体）。
extension WindowController {
  /// surface 経路（`TerminalController.onWindowCommand`）と window レベル経路
  /// （`ChromeHostingView.performKeyEquivalent`）が共有する実体。
  func handleWindowCommand(_ command: TerminalController.WindowCommand) {
    switch command {
    case .newTab: newTab()
    case .nextTab: nextTab()
    case .prevTab: prevTab()
    case .prevTool: navigateEditorTool(-1)
    case .nextTool: navigateEditorTool(1)
    case .switchWorkspace: showWorkspacePalette()
    case .newWorkspace: showWorkspaceCreate()
    case .toggleEditorPane: toggleEditorPane()
    case .launchDefaultAgent: agentLauncher.launchDefault()
    case .showAgentPalette: agentLauncher.showPalette()
    case .showDispatchPalette: showDispatchPalette()
    case .openEditor: EditorLauncher.openCwd(store.activePaneCwd(), localization: localization)
    case .renameTab: beginTabRename()
    case .showSettings: showSettingsPalette()
    }
  }

  /// window レベルの pane 非依存コマンドのハンドラ。overlay 表示中・タブのインライン改名中は不活性
  /// （パレット入力中／改名編集中の window コマンド暴発を防ぐ）。surface の有無に依らず届く。
  func handleWindowKeyCommand(_ command: TerminalController.WindowCommand) -> Bool {
    guard model.overlay == .none, statusModel.editingIndex == nil else { return false }
    handleWindowCommand(command)
    return true
  }
}
