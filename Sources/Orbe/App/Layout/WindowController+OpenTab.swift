import AppKit

/// 新タブの生成（`openTab`）と、背景 workspace での surface 起こし（`materializeOffscreen`）。
extension WindowController {
  /// `openTab` が起こした 1 枚の宛先 id 一式。制御 API の応答（`{paneId, tabId, workspaceId}`）は
  /// これをそのまま写す。
  struct OpenedTab {
    let paneId: Int
    let tabId: Int
    let workspaceId: Int
  }

  /// 新タブを 1 枚起こす唯一の経路。GUI（Cmd+T・エージェント起動・Dispatch・workspace 作成）と
  /// 制御 API（spawn / spawn_agent / resume_agent）が同じ本体を通る——起動のされ方が経路ごとに
  /// 割れると、その差は「GUI からは動くが CLI からは動かない」という形で後から必ず出る。
  ///
  /// `cwd` 省略は対象 workspace のアクティブペイン cwd → その workspace の rootPath へ落ちる
  /// （`newSurfaceCwd(inWorkspaceAt:)`）。戻り値は生えたペイン・タブ・workspace の id で、
  /// workspaceIndex が範囲外ならタブを作らず nil。
  @discardableResult
  func openTab(
    workspaceIndex: Int, cwd: String?, command: String? = nil, env: [String: String] = [:]
  ) -> OpenedTab? {
    guard workspaces.indices.contains(workspaceIndex) else { return nil }
    let initialCwd = cwd ?? store.newSurfaceCwd(inWorkspaceAt: workspaceIndex)
    let tc = wire(
      TerminalController(initialCwd: initialCwd, initialCommand: command, initialEnv: env))
    store.appendTab(tc, toWorkspaceAt: workspaceIndex)  // 背景 WS はここで active も末尾へ
    if workspaceIndex == activeWorkspace {
      select(workspaces[workspaceIndex].tabs.count - 1)  // surface を起こす（mount）
    } else {
      materializeOffscreen(tc)
    }
    scheduleSave()
    guard let paneId = tc.controlAllPanes().first?.id else { return nil }
    return OpenedTab(
      paneId: paneId, tabId: tc.id, workspaceId: workspaces[workspaceIndex].id)
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
  /// `OrbeCliAgentProcessTests` の背景 workspace 1 本が持つ——外すと、返した paneId は
  /// 「画面が読めず入力も届かない」ものに退化する。
  private func materializeOffscreen(_ tc: TerminalController) {
    tc.rootContainer.autoresizingMask = [.width, .height]
    tc.rootContainer.frame = model.content.bounds  // pty winsize を実サイズで起こす
    tc.rootContainer.isHidden = true
    model.content.addSubview(tc.rootContainer)  // viewDidMoveToWindow → createSurface
    tc.rootContainer.removeFromSuperview()  // detach。surface は生存
  }
}
