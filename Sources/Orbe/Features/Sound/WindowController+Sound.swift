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
    soundPlayer.play(plan.source, event: plan.event, volume: plan.volume)
  }

  /// 取り込み済み音源の後始末。**参照集合が変わったとき**にだけ呼ぶ（カスタム音源の設定値を
  /// 書いた直後＝`applySetting`、workspace を削除した直後＝`closeWorkspace`）。
  ///
  /// 参照集合は global 層と全 workspace の上書き層をそのまま走査して組む——in-memory の層が
  /// 設定の SSOT なので、ディスクへの保存が debounce されていても取りこぼさない。
  /// 順序は必ず「新ファイルを書く → 設定値を差し替える → GC」。逆順だと、書いたばかりで
  /// まだ誰も参照していないファイルを消してしまう。
  func collectCustomSoundGarbage() {
    var referenced: Set<String> = []
    var layers = [settingsStore.global]
    layers += workspaces.compactMap(\.settingsOverride)
    for layer in layers {
      // 対象 key は `SettingKeys.customSoundSources` が SSOT（GC の契機判定も同じ列を読む）。
      referenced.formUnion(SettingKeys.customSoundSources.compactMap { layer[$0]?.file })
    }
    CustomSoundStore.collectGarbage(referenced: referenced)
  }

  /// ペインが属する workspace（`attentionRow(for:)` と同じ activatedタブの走査）。
  private func workspace(of pane: SurfaceView) -> Workspace? {
    for ws in workspaces {
      for tab in ws.tabs
      where tab.activated && tab.controlAllPanes().contains(where: { $0 === pane }) { return ws }
    }
    return nil
  }
}
