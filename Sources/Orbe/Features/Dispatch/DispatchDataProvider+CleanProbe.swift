import Foundation

/// プローブ発行の範囲。**差分発行は全量発行が一度走った後にしか成立しない**——比較先の台帳
/// （`issuedProbeTargets`）が無いまま差分を撃つと「台帳に無い＝比較先が変わった」と読んで全行が
/// 飛ぶ。それは `fetch --prune` の前に到達性を計算するということで、prune 前の
/// `refs/remotes/origin/*` には remote で消えた ref が残っているので結論が偽になりうる。
/// この前提を呼び出し側の裸の真偽値に委ねず、**名前（この型）と関門（`case changedTargets` の
/// `guard`）の両方**で持つ。
enum CleanProbeScope {
  /// git の事実（ref の中身）が動いた着地——`fetch --prune` 後と削除後。全行を撃ち、台帳と世代を
  /// 張り直す。**分類が始まる唯一の入口**でもある。
  case all
  /// gh 着地。**比較先の顔ぶれが変わった行だけ**を撃つ（merged PR の base が判明して
  /// `origin/<base>` が比較先に加わった行がこれに当たる）。台帳がまだ無い＝全量が一度も走って
  /// いない＝prune 前なので、そのときは 1 本も撃たず prune 後の全量発行へ合流させる
  /// ——その全量発行は着地済みの gh ヒントを込みで比較先を組むので、取りこぼしにはならない。
  case changedTargets
}

/// 分類レーン（プローブ）の発行と着地。**行ごとの準備完了を決める帳簿**をここに閉じる——
/// 「何を撃ったか」（比較先の台帳・世代）と「何本が未着地か」（多重集合）が同じ場所にある。
/// 描画は本体の `rebuild()` へ流す。
extension DispatchDataProvider {

  /// 分類レーンを起動する。撃つ範囲は `scope` が持つ。
  ///
  /// 台帳（`issuedProbeTargets`）は**発行の時点で**更新する——着地を待って記録すると、その間に来た
  /// もう一方の着地点が同じ顔ぶれを二重に引く（`loadBranchPullRequests` と同じ理由）。
  ///
  /// 着地は 2 つの関門を通ったものだけ `cleanProbes` へマージする。probe は独立レーン
  /// （concurrent）で順序保証が無く、古い発行の遅着が新しい結果を上書きしうるため:
  /// **世代**（全量発行より後に撃たれた全量発行があれば、古い方の着地は丸ごと捨てる）と、
  /// **path ごとの比較先の照合**（全量発行の在庫中に gh 着地で比較先が変わった行は、その行だけ
  /// 差分発行の結果を勝たせる）。前者だけでは同一比較先の全量どうしを、後者だけでは
  /// prune 前後の全量どうしを弾けないので、両方が要る。
  func startCleanProbe(_ repo: GitRepo, _ scope: CleanProbeScope) {
    let extra = DispatchWorktreeClassifier.extraContainmentTargets(
      worktrees: worktrees, branchPullRequests: landedBranchPRs,
      remoteBranchNames: Set(remoteBranches.map(\.name)), defaultBranch: defaultBranchName)
    let prober = DispatchCleanProber(
      repo: repo, defaultBranch: defaultBranchName, extraContainmentTargets: extra)
    // 台帳は prober が実際に渡す比較先そのもの（合成点を 1 つにして、記録と実入力がずれないようにする）。
    let inputs = Dictionary(
      uniqueKeysWithValues: worktrees.map { ($0.path, prober.targets(for: $0.path)) })
    let stale: [GitWorktree]
    switch scope {
    case .all:
      // 対象 0 本でも台帳は張る（＝分類は「全行ぶん済んだ」で着地する）。ここで返ると台帳が無いまま
      // 残り、`cleanProbes` も nil のままなので clean はスケルトンを回し続ける——全量発行の入口は
      // prune と削除の 2 つだけなので、そこから自力では抜けられない。
      stale = worktrees
      issuedProbeTargets = inputs
      probeGeneration += 1
    case .changedTargets:
      // 台帳が無い＝全量発行がまだ一度も走っていない（＝prune 前）。差分の前提そのものが無い。
      guard var ledger = issuedProbeTargets else { return }
      stale = worktrees.filter { inputs[$0.path] != ledger[$0.path] }
      guard !stale.isEmpty else { return }
      for worktree in stale { ledger[worktree.path] = inputs[worktree.path] }
      issuedProbeTargets = ledger
    }
    for worktree in stale { probingPaths[worktree.path, default: 0] += 1 }
    let generation = probeGeneration
    prober.probe(worktrees: stale, tabs: tabOccupancies) { [weak self] probes in
      guard let self else { return }
      // 減らすのは**世代照合より前**。捨てる着地でも発行の 1 本は終わっているので、ここを飛ばすと
      // その path が永遠に「取得中」＝選べないまま残る。
      for worktree in stale { self.finishProbe(at: worktree.path) }
      if generation == self.probeGeneration {
        var merged = (self.cleanProbes ?? [:]).filter { self.issuedProbeTargets?[$0.key] != nil }
        for (path, probe) in probes where inputs[path] == self.issuedProbeTargets?[path] {
          merged[path] = probe
        }
        self.cleanProbes = merged
      }
      // 実測を採らなかった回（世代照合で捨てた着地）でも描き直す——帳簿が動いた＝行の準備完了が
      // 動いたということで、ここを飛ばすと最後に着地した古い世代のぶんだけ行が選べないまま残る。
      self.rebuild()
    }
  }

  /// 発行済みプローブ 1 本の決着を帳簿へ返す（0 になったキーは落とす）。
  private func finishProbe(at path: String) {
    guard let count = probingPaths[path] else { return }
    if count <= 1 {
      probingPaths.removeValue(forKey: path)
    } else {
      probingPaths[path] = count - 1
    }
  }
}
