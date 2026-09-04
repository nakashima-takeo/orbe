import AppKit
import OrbeSound

/// エージェント状態の変化を通知音へ流す。メニューバー②と並ぶ、1 つの通知（`AgentNotice`）の
/// 2 つ目の投影面。
extension WindowController {
  /// 通知 1 件を鳴らす。鳴らすかどうか（状態・オン/オフ・音源）は `AgentSoundDecision` が
  /// 通知の持つ発信元 workspace の実効設定から決める。
  func noteAgentSound(_ notice: AgentNotice) {
    guard let plan = AgentSoundDecision.plan(state: notice.row.state, settings: notice.settings)
    else { return }
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
}
