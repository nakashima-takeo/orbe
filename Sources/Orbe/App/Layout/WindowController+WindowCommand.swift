import AppKit

/// window コマンドのディスパッチ（surface 経路・window レベル経路の共通実体）。
extension WindowController {
  /// surface 経路（`TerminalTab.onWindowCommand`）と window レベル経路
  /// （`ChromeHostingView.performKeyEquivalent`）が共有する実体。
  func handleWindowCommand(_ command: WindowCommand) {
    switch command {
    case .newTab: newTab()
    case .showClosedAgentsPalette: showClosedAgentsPalette()
    case .nextTab: nextTab()
    case .prevTab: prevTab()
    case .switchWorkspace: showWorkspacePalette()
    case .launchDefaultAgent: agentLauncher.launchDefault()
    case .showAgentPalette: agentLauncher.showPalette()
    case .showDispatchPalette: showDispatchPalette()
    case .openEditor: openEditor()
    case .renameTab: beginTabRename()
    case .showSettings: showSettingsPalette()
    case .toggleHelp: showHelp()
    }
  }

  /// アクティブタブの cwd を GUI エディタでフォルダとして開く（Cmd+Shift+E）。
  /// cwd 不明はビープ、エディタ未検出は NSAlert（現在言語）。
  private func openEditor() {
    guard let cwd = store.activeTabCwd() else {
      NSSound.beep()
      return
    }
    guard let editor = EditorLauncher.resolve() else {
      let alert = NSAlert()
      alert.messageText = localization.string(.editorNotFoundTitle)
      alert.informativeText = localization.string(.editorNotFoundMessage)
      alert.runModal()
      return
    }
    EditorLauncher.open(cwd, editor: editor)
  }

  /// window レベルのタブ非依存コマンドのハンドラ。overlay 表示中・タブのインライン改名中は不活性
  /// （パレット入力中／改名編集中の window コマンド暴発を防ぐ）。surface の有無に依らず届く。
  func handleWindowKeyCommand(_ command: WindowCommand) -> Bool {
    // ⌘H はトグル: help 表示中の再打鍵だけは overlay ガードの前で閉じ側として消費する
    // （他 overlay 表示中は従来どおり不活性＝他パレットのキーと同じ規律）。
    if command == .toggleHelp, model.overlay == .help {
      dismissHelp()
      return true
    }
    guard model.overlay == .none, statusModel.editingIndex == nil else { return false }
    handleWindowCommand(command)
    return true
  }
}
