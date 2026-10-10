import AppKit

/// 構成変化のデバウンス保存・終了時 flush と、保存ファイル／休眠チケットからの復元。
/// WindowController 本体から永続化の読み書き両面を分離する。
extension WindowController {
  /// 保存ファイルから workspaces/タブ/ウィンドウサイズを起こす（起動時に init から 1 回）。
  func restore(from file: WorkspacesFile) {
    restoreWindowSize(file.windowSize)
    var restored: [Workspace] = []
    for state in file.workspaces {
      let ws = Workspace(
        name: state.name, rootPath: state.rootPath, persistentId: state.persistentId)
      ws.lastUsedAt = state.lastUsedAt  // MRU 並べ替えキーを読み戻す（旧データは nil）
      ws.settingsOverride = state.settingsOverride  // 設定上書きを読み戻す（旧データは nil＝global 継承）
      ws.lastWorktreeBase = state.lastWorktreeBase
      for tab in state.tabs { ws.tabs.append(makeTab(from: tab)) }  // 隣接の正規化は下の store.load
      // 0タブ（休眠）workspace はそのまま残す。アクティブ化（切替・下の activateCurrent）は空表示
      // で、シェルは自動起動しない。背景の休眠 workspace も空のまま keep する。ボードを持つかは Home を知る
      // store.load が決め、そこで選択も不変条件へそろえる。
      if state.boardSelected {
        ws.selection = .board
      } else if !ws.tabs.isEmpty {
        ws.selection = .tab(ws.tabs[min(max(0, state.activeTab), ws.tabs.count - 1)])
      }
      restored.append(ws)
    }
    // workspaces 非空は load() が保証する（空 workspaces のファイルは load が nil を返す）。
    store.load(
      workspaces: restored,
      activeWorkspace: min(max(0, file.activeWorkspace), restored.count - 1),
      homeWorkspaceId: file.homeWorkspaceId)
    activateCurrent()  // 復元アクティブが0タブ（休眠保存）なら空表示（シェルは起こさない）
  }

  /// TabState 1 枚からタブを起こして配線する。起動時復元（restore）・`restoreDormantTab`・`openResumedTab` の共通経路
  /// ——agent 付きは休眠チケットのまま起こし、resume 解決（と解決不能時の素シェル化）は
  /// タブ起床時に走る（`TerminalTab.recordMaterializationStarted`）。ここは resolver を渡すだけ。会話の再開の組み立ては
  /// すべてこの resolver を通る。起こす会話が秘書の会話なら、秘書の係がそのタブを秘書として覚え、秘書の役割の指示を
  /// 再開に添える（起こす時点の秘書の記録で決まる）。
  func makeTab(from state: TabState) -> TerminalTab {
    let resume: TerminalTab.ResumeSpawn = { [weak self, agentLauncher] tab, session, input in
      agentLauncher.resumeSpawn(
        for: session, arguments: self?.secretary.launching(session, in: tab) ?? [],
        firstInput: input)
    }
    return wire(TerminalTab(restoring: state, resumeSpawn: resume, editorSurfaces: editorSurfaces))
  }

  /// 休眠チケット 1 枚を workspace へ足す。`restore_sessions` と ⇧⌘T が共有する復元単位。
  /// 起動時復元と `makeTab` を共有するが、閉じたセッションの復元が持ち込むのは cwd と同一性だけ
  /// （明示タイトルは付かない）。位置は新規タブと同じ規則——同じ worktree の連の右端、無ければ末尾。
  /// 選択・mount はしない（起床は既存の mount 規律に従う）。
  func restoreDormantTab(_ state: TabState, intoWorkspaceAt index: Int) -> TabRef {
    let tab = makeTab(from: state)
    let tabIndex = store.insertTabUnselected(tab, intoWorkspaceAt: index)
    refreshChrome()
    scheduleSave()
    return TabRef(workspaceIndex: index, tabIndex: tabIndex, tab: tab)
  }

  // ユーザーのリサイズ確定で意図サイズを記憶し、保存を予約する（高頻度なドラッグはデバウンスでまとまる）。
  // 復元時の programmatic な setFrame による発火はフラグで弾く（クランプ縮小値を拾わない）。
  func windowDidResize(_ notification: Notification) {
    guard !isApplyingRestoredSize else { return }
    rememberedWindowSize = WindowSize(
      width: Double(window.frame.size.width), height: Double(window.frame.size.height))
    scheduleSave()
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

  /// worktree パレットで新しいブランチを作れたときのベースを、その workspace の「前回」として覚える
  /// （実行時にこの値を書く唯一の窓口。パレットとデータ供給には触らせない）。workspace が既に
  /// 閉じられていたら書かない。
  func rememberWorktreeBase(_ base: String, in workspace: Workspace) {
    guard workspaces.contains(where: { $0 === workspace }) else { return }
    workspace.lastWorktreeBase = base
    scheduleSave()
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
          name: ws.name, rootPath: ws.rootPath, activeTab: ws.selectedTabIndex ?? 0,
          boardSelected: ws.selection == .board,
          tabs: ws.tabs.map { $0.tabState() },
          lastUsedAt: ws.lastUsedAt, settingsOverride: ws.settingsOverride,
          lastWorktreeBase: ws.lastWorktreeBase, persistentId: ws.persistentId)
      },
      windowSize: rememberedWindowSize, homeWorkspaceId: store.homeWorkspaceId)
  }
}
