import AppKit

/// 構成変化のデバウンス保存と終了時 flush。WindowController 本体から保存系を分離する。
extension WindowController {
  // ユーザーのリサイズ確定で意図サイズを記憶し、保存を予約する（高頻度なドラッグはデバウンスでまとまる）。
  // 復元時の programmatic な setFrame による発火はフラグで弾く（クランプ縮小値を拾わない）。
  func windowDidResize(_ notification: Notification) {
    guard !isApplyingRestoredSize else { return }
    rememberedWindowSize = WindowSize(
      width: Double(window.frame.size.width), height: Double(window.frame.size.height))
    scheduleSave()
  }

  /// 永続スナップショットから全 workspace・タブ・分割ツリーを再構築する（init の復元経路）。
  func restore(from file: WorkspacesFile) {
    restoreWindowSize(file.windowSize)
    let resume: TerminalController.ResumeSpawn = { [agentLauncher] in
      agentLauncher.resumeSpawn(for: $0)
    }
    var restored: [Workspace] = []
    for state in file.workspaces {
      let ws = Workspace(name: state.name, rootPath: state.rootPath)
      ws.lastUsedAt = state.lastUsedAt  // MRU 並べ替えキーを読み戻す（旧データは nil）
      ws.settingsOverride = state.settingsOverride  // 設定上書きを読み戻す（旧データは nil＝global 継承）
      for tab in state.tabs {
        let tc = TerminalController(restoring: tab.tree, resumeSpawn: resume)
        tc.explicitTitle = tab.explicitTitle
        tc.editorUI.paneOpen = tab.editor.open
        tc.editorUI.tool = EditorTool(persistKey: tab.editor.tool)
        ws.tabs.append(wire(tc))
      }
      // 0タブ（休眠）workspace はそのまま残す。アクティブ化（切替・activateCurrent）は空表示
      // で、シェルは自動起動しない。背景の休眠 workspace も空のまま keep する。
      ws.active = ws.tabs.isEmpty ? 0 : min(max(0, state.activeTab), ws.tabs.count - 1)
      restored.append(ws)
    }
    // workspaces 非空は load() が保証する（空 workspaces のファイルは load が nil を返す）。
    store.load(
      workspaces: restored,
      activeWorkspace: min(max(0, file.activeWorkspace), restored.count - 1))
    activateCurrent()  // 復元アクティブが0タブ（休眠保存）なら空表示（シェルは起こさない）
  }

  /// 記憶サイズ（クランプ前の意図サイズ）を保持しつつ、起動時画面（visibleFrame）にクランプして
  /// 適用する。位置は触らない（init 末尾の center() が毎回中央化する）。保存値が無ければ init 生成の
  /// 800×500 を残す。クランプは表示用で記憶は元サイズのまま——小画面で開いても次回大画面で元に戻せる。
  func restoreWindowSize(_ size: WindowSize?) {
    guard let size else { return }
    rememberedWindowSize = size
    let visible = (window.screen ?? NSScreen.main)?.visibleFrame.size
    let width = min(size.width, Double(visible?.width ?? .greatestFiniteMagnitude))
    let height = min(size.height, Double(visible?.height ?? .greatestFiniteMagnitude))
    isApplyingRestoredSize = true
    window.setFrame(
      NSRect(x: window.frame.origin.x, y: window.frame.origin.y, width: width, height: height),
      display: false)
    isApplyingRestoredSize = false
  }

  /// 構成が変わったら 1 秒のデバウンス後に 1 回保存する（高頻度な cwd 報告をまとめる）。
  func scheduleSave() {
    pendingSave?.cancel()
    let work = DispatchWorkItem { [weak self] in self?.saveNow() }
    pendingSave = work
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: work)
  }

  /// 終了時などにデバウンス待ちを取りこぼさず確定保存する。
  func flushSave() {
    pendingSave?.cancel()
    pendingSave = nil
    WorkspacePersistence.save(snapshotFile())
  }

  private func saveNow() {
    pendingSave = nil
    WorkspacePersistence.save(snapshotFile())
  }

  private func snapshotFile() -> WorkspacesFile {
    WorkspacesFile(
      version: WorkspacePersistence.version,
      activeWorkspace: activeWorkspace,
      workspaces: workspaces.map { ws in
        WorkspaceState(
          name: ws.name, rootPath: ws.rootPath, activeTab: ws.active,
          tabs: ws.tabs.map {
            TabState(
              tree: $0.snapshot(), explicitTitle: $0.explicitTitle,
              editor: EditorPaneTabState(
                open: $0.editorUI.paneOpen, tool: $0.editorUI.tool.persistKey))
          },
          lastUsedAt: ws.lastUsedAt, settingsOverride: ws.settingsOverride)
      },
      windowSize: rememberedWindowSize)
  }
}
