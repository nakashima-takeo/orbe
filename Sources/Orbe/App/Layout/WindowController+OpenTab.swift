import AppKit

/// 新タブの生成（`openTab`）と、背景 workspace での surface 起こし（`materializeOffscreen`）。
extension WindowController {
  /// `openTab` が起こした 1 枚の宛先 id 一式。制御 API の応答（`{tabId, workspaceId}`）は
  /// これをそのまま写す。
  struct OpenedTab {
    let tabId: Int
    let workspaceId: Int
  }

  /// 新タブを 1 枚起こす唯一の経路。GUI（初回起動・エージェント起動・worktree パレット（Cmd+T・タブ行の
  /// 「＋」）・workspace 作成）と制御 API（spawn / spawn_agent / resume_agent）が同じ本体を通る——起動の
  /// され方が経路ごとに割れると、その差は「GUI からは動くが CLI からは動かない」という形で後から必ず出る。
  ///
  /// `cwd` に nil を渡すと対象 workspace のアクティブタブの cwd → その workspace の rootPath へ落ちる
  /// （`newTabCwd(inWorkspaceAt:)`）。戻り値は生えたタブ・workspace の id で、
  /// workspaceIndex が範囲外ならタブを作らず nil。`selects` が偽なら選ばずに起こす（`wakeUnselected`）——人が
  /// 見ている workspace とタブを変えずに、裏で agent を起こす経路（秘書・`start_task`）が使う。
  @discardableResult
  func openTab(
    workspaceIndex: Int, cwd: String?, command: String? = nil, env: [String: String] = [:],
    selects: Bool = true
  ) -> OpenedTab? {
    guard workspaces.indices.contains(workspaceIndex) else { return nil }
    let initialCwd = cwd ?? store.newTabCwd(inWorkspaceAt: workspaceIndex)
    let tab = wire(
      TerminalTab(cwd: initialCwd, command: command, env: env, editorSurfaces: editorSurfaces))
    return place(tab, workspaceIndex: workspaceIndex, selects: selects)
  }

  /// 会話を新しいタブで再開する（続きから・`resume_agent`・秘書）。休眠のタブとして足して `openTab` と同じ規則で
  /// 起こすので、再開の組み立ては休眠のタブの起床（`makeTab` の resolver）の 1 か所を通る。開いた時点で会話のタブの
  /// 索引に載る（続けて同じ会話を開こうとしても、このタブが見つかる）。`firstInput` は会話の最初の入力。
  @discardableResult
  func openResumedTab(
    _ session: AgentSession, workspaceIndex: Int, cwd: String?, firstInput: String? = nil,
    selects: Bool = true
  ) -> OpenedTab? {
    guard workspaces.indices.contains(workspaceIndex) else { return nil }
    let tab = makeTab(
      from: TabState(
        cwd: cwd ?? store.newTabCwd(inWorkspaceAt: workspaceIndex), agent: session,
        explicitTitle: nil))
    if let firstInput { tab.addWakeInput(firstInput) }
    let opened = place(tab, workspaceIndex: workspaceIndex, selects: selects)
    refreshAgentSessionTabs()
    return opened
  }

  private func place(_ tab: TerminalTab, workspaceIndex: Int, selects: Bool) -> OpenedTab {
    if selects {
      store.insertTab(tab, intoWorkspaceAt: workspaceIndex)  // 背景 WS はここで選択も新タブへ
      if workspaceIndex == activeWorkspace {
        select(.tab(tab))  // surface を起こす（mount）
      } else {
        materializeOffscreen(tab, in: workspaces[workspaceIndex])
      }
    } else {
      _ = store.insertTabUnselected(tab, intoWorkspaceAt: workspaceIndex)
      wakeUnselected(tab)
    }
    scheduleSave()
    return OpenedTab(tabId: tab.id, workspaceId: workspaces[workspaceIndex].id)
  }

  /// 既にあるタブ（休眠のタブを含む）の surface を、選ばずに起こす。休眠のタブは起こす時点で再開が走る。
  /// 背景 workspace なら前面化せずに起こし（`materializeOffscreen`）、前面の workspace なら隠れタブとして mount する。
  /// 前面の workspace の選択がそのタブなら（空表示だった workspace に足したタブ）、隠すと「選んでいるタブが見えない」状態に
  /// なるので、選んで見せる。ボードを持つ workspace は空にならないので、そのタブはボードの裏で起きる。
  func wakeUnselected(_ tab: TerminalTab) {
    guard
      let index = workspaces.firstIndex(where: { ws in ws.tabs.contains { $0 === tab } })
    else { return }
    let ws = workspaces[index]
    guard index == activeWorkspace else { return materializeOffscreen(tab, in: ws) }
    if ws.selectedTab === tab { return select(ws.selection) }
    mountTab(tab, in: ws, visible: false)
    refreshChrome()
  }

  /// 背景 workspace に生えたタブの surface を、前面化せずに起こす。
  ///
  /// surface は「一度 window に attach された時点で誕生し、detach しても生き続ける」
  /// （`SurfaceView.viewDidMoveToWindow` は `surface == nil` の初回だけ生成し、解放は deinit のみ）。
  /// 可視である必要はない——隠れタブの遅延 mount が既にこの性質に依っている。よって「隠したまま
  /// 一瞬 attach して外す」と、workspace 切替で背景に回ったタブと**同一の状態**に着地する。
  /// アクティブ workspace は動かないので、手元の画面は切り替わらない。
  ///
  /// workspace 単位 keep-alive の遅延 mount（休眠 workspace の復元でシェルを N 個いきなり
  /// 起こさない）とは背反しない。あちらは「既にあるタブの復元」の方針で、こちらは「今まさに
  /// 作れと言われた 1 枚」だから。
  ///
  /// attach と detach を**同じ turn で完結できる**ことは実測で確かめてある（AppKit が
  /// `viewDidMoveToWindow` を `addSubview` の中で同期発火する）。ここが成立しているかの合否は
  /// `OrbeCliAgentProcessTests` の背景 workspace 1 本が持つ——外すと、返した tabId は
  /// 「画面が読めず入力も届かない」ものに退化する。同じテストが surface のサイズも見る。
  private func materializeOffscreen(_ tab: TerminalTab, in ws: Workspace) {
    guard store.recordMaterialization(of: tab, in: ws) else { return }
    // 素シェルを背景 workspace に起こす場合 `agentSlot` は変わらず、`activated` の反転だけが起きる。
    // ここで要求しないと減光解除が chrome 更新点（`flushChrome`）へ届かない。
    refreshChrome()
    tab.view.autoresizingMask = [.width, .height]
    tab.view.frame = model.content.bounds
    tab.view.isHidden = true
    // surface のサイズは `SurfaceScrollView.layout()` だけが配り、それが走るのは window の display
    // サイクル。同じ turn で detach する以上そのサイクルは来ないので、ここで同期に確定させる
    // ——さもないと `SurfaceView` は 0 サイズのまま `createSurface` を迎え、`updateSize` の
    // ゼロ面積ガードに弾かれて pty が libghostty 既定サイズのまま起きる（前面化するまで直らない）。
    tab.view.layoutSubtreeIfNeeded()
    model.content.addSubview(tab.view)  // viewDidMoveToWindow → createSurface
    tab.view.removeFromSuperview()  // detach。surface は生存
  }
}
