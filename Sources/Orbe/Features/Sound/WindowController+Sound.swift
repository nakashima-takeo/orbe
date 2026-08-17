import AppKit
import OrbeSound

/// エージェント状態の変化を通知音へ流す。`noteAttentionTransient`（メニューバー②）と同じ発火点・
/// 同じ抑制条件で並ぶ 3 番目の利用者。
extension WindowController {
  /// waiting / done への実変化で鳴らす。ただし発信元ペインが**見ているタブ**にあるときは鳴らさない
  /// ——端末にその結果もプロンプトも出ている面で、注意を二重に奪わないため（②の抑制と 1 文字も違えない）。
  func noteAgentSound(for pane: SurfaceView, state: String) {
    if let visibleTab, pane.controller === visibleTab { return }
    // 設定は**発信元ペインが属する workspace の実効値**を読む。workspace 上書き（「この workspace の
    // エージェントはこの音」）が意味を持つのはこの読み方だけ。
    // 所属が引けない＝未activatedタブのペイン。②が「幽霊ピルになる」として立てないのと同じ集合を
    // 見る——一覧にもピルにも出ない音だけが鳴ると、ユーザは出所を辿れない。
    guard let ws = workspace(of: pane) else { return }
    let settings = settingsStore.effective(override: ws.settingsOverride)
    guard let plan = AgentSoundDecision.plan(state: state, settings: settings) else { return }
    soundPlayer.play(plan.family, event: plan.event, volume: plan.volume)
  }

  /// ペインが属する workspace（`attentionRow(for:)` と同じ activatedタブの走査）。
  private func workspace(of pane: SurfaceView) -> Workspace? {
    for ws in workspaces where ws.activated {
      for tab in ws.tabs
      where tab.activated && tab.controlAllPanes().contains(where: { $0 === pane }) { return ws }
    }
    return nil
  }
}
