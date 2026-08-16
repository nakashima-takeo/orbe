import Foundation

/// 分類レーン（プローブ）の発行と着地。**行ごとの準備完了を決める帳簿**をここに閉じる——
/// 「何を撃ったか」（比較先の台帳・世代）と「何本が未着地か」（多重集合）が同じ場所にある。
/// 描画は本体の `rebuild()` へ流す。
extension DispatchDataProvider {

  /// 分類レーンを起動する。fetch 着地後にも同じ入口から取り直す（結果が同じなら rebuild しない）。
  ///
  /// `invalidateAll` が false のとき（gh 着地）は、**比較先の顔ぶれが変わった行だけ**を引き直す
  /// （merged PR の base が判明して `origin/<base>` が比較先に加わった行がこれに当たる）。
  /// 台帳（`issuedProbeTargets`)は**発行の時点で**更新する——着地を待って記録すると、その間に来た
  /// もう一方の着地点が同じ顔ぶれを二重に引く（`loadBranchPullRequests` と同じ理由）。
  ///
  /// 着地は 2 つの関門を通ったものだけ `cleanProbes` へマージする。probe は独立レーン
  /// （concurrent）で順序保証が無く、古い発行の遅着が新しい結果を上書きしうるため:
  /// **世代**（全量発行より後に撃たれた全量発行があれば、古い方の着地は丸ごと捨てる）と、
  /// **path ごとの比較先の照合**（全量発行の在庫中に gh 着地で比較先が変わった行は、その行だけ
  /// 差分発行の結果を勝たせる）。前者だけでは同一比較先の全量どうしを、後者だけでは
  /// prune 前後の全量どうしを弾けないので、両方が要る。
  func startCleanProbe(_ repo: GitRepo, invalidateAll: Bool) {
    let extra = DispatchWorktreeClassifier.extraContainmentTargets(
      worktrees: worktrees, branchPullRequests: landedBranchPRs,
      remoteBranchNames: Set(remoteBranches.map(\.name)), defaultBranch: defaultBranchName)
    let prober = DispatchCleanProber(
      repo: repo, defaultBranch: defaultBranchName, extraContainmentTargets: extra)
    // 台帳は prober が実際に渡す比較先そのもの（合成点を 1 つにして、記録と実入力がずれないようにする）。
    let inputs = Dictionary(
      uniqueKeysWithValues: worktrees.map { ($0.path, prober.targets(for: $0.path)) })
    let stale =
      invalidateAll
      ? worktrees : worktrees.filter { inputs[$0.path] != issuedProbeTargets?[$0.path] }
    guard !stale.isEmpty else { return }
    if invalidateAll {
      issuedProbeTargets = inputs
      probeGeneration += 1
    } else {
      var ledger = issuedProbeTargets ?? [:]
      for worktree in stale { ledger[worktree.path] = inputs[worktree.path] }
      issuedProbeTargets = ledger
    }
    for worktree in stale { probingPaths[worktree.path, default: 0] += 1 }
    let generation = probeGeneration
    prober.probe(worktrees: stale, panes: paneOccupancies) { [weak self] probes in
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
