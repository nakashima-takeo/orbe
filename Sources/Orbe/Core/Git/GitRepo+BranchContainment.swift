import Foundation

// MARK: - ブランチ取り込み判定（消してコミットが世界に残るか）

/// ブランチ削除の安全判定の結論。「消して世界に残るか」を、証明の種類ごとに別のケースで語る
/// （0 という数値に「取り込み済み」を兼務させない——到達性の証明と patch 等価の証明はラベルが違う）。
///
/// payload は**渡された比較先の名前そのまま**（`"main"`・`"origin/develop"` 等の事実）を運ぶ。
/// 表示用の `origin/` 剥がしは分類器が行う。
enum GitBranchContainment: Equatable {
  /// 全コミットが `refs/remotes/origin/*` から到達可能（消してもコミットはそこに残る）。
  /// **origin に限るのは鮮度の保証範囲と揃えるため**——Orbe が prune するのは origin だけなので、
  /// 他 remote の tracking ref は remote 側で消えた後もローカルに残り続け、「世界に残る」の根拠にできない。
  /// `mergedInto` は tip を含む最初の比較先（ラベル「merged → \<X\>」を名乗れるか）で、
  /// 安全事実そのものには関わらない。無ければ nil（到達性だけを主張する `リモート反映済み`）。
  case reachable(mergedInto: String?)
  /// `target` に patch 等価で存在（cherry 2 段）。ラベルは「merged → \<target\>」。
  case patchEquivalent(target: String)
  /// 未取り込み。`count` は失われうるコミット数（到達不能数と patch 非等価数の min）。
  case unmerged(count: Int)
}

extension GitRepo {

  /// 判定 1 本ぶんの不変な文脈。多段（第0〜2段）の再帰が同じ値を運ぶための束。
  private struct ContainmentProbe {
    /// 判定対象（完全 ref または oid）。
    let branchOrCommit: String
    /// 第0段の到達不能数（第0段が失敗したら nil。count の min に使う）。
    let reachCount: Int?
    let lane: GitRunner.Lane
  }

  /// ブランチを消して「コミットが世界に残るか」の判定。判定できなければ nil（安全と読まない）。
  ///
  /// `targets` は比較先リスト（非空・先頭が既定ブランチ・順序が優先順）。gh のヒント（merged PR の
  /// base）で 1 本増えることがあるが、**証明は完全にローカル**——嘘の base は cherry の不成立で
  /// 確認群のままに倒れる。複数比較先が同時に立つときのラベルは**先に立った段**が勝ち、同じ段の
  /// 中ではリスト順＝既定優先（第1段は全 target を先に回すので、既定への squash 取り込みより
  /// 後続 target への素の patch 等価が先に立つ）。
  ///
  /// **3 段構え**。第0段は到達性——`rev-list --count <tip> --not --remotes=origin --` が 0 なら、
  /// 全コミットが `refs/remotes/origin/*` から到達可能で、worktree とローカルブランチを消しても
  /// コミットはそこに残る。比較先の推測なしに安全群の意味論（消して世界に残るか）を直接問えるので、
  /// 統合先が既定ブランチでないリポジトリ（git-flow の develop 統合等）でも成立する。
  /// squash/rebase マージは SHA が変わって到達性で見えないため、第1段（素の `git cherry`）・
  /// 第2段（累積差分のダングリングコミットで再 cherry）が比較先との patch 等価で拾う。
  ///
  /// **`--remotes` ではなく `--remotes=origin`。** 信頼する ref の集合は、Orbe が鮮度を保証する集合と
  /// 一致していなければならない。prune するのは `fetchPrune` の origin だけなので、fork や upstream の
  /// tracking ref は remote 側で消えた後も残り続ける。それを根拠にすると、`[gone]` で安全群に入った行が
  /// stale な ref だけを頼りにブランチごと消え、ユーザーが後で全 remote を prune した時点でコミットが
  /// 到達不能になる。origin に限れば「`[gone]` を作る prune」と「信頼する ref を掃除する prune」が
  /// 同一操作になり、その組み合わせが構造的に消える。
  ///
  /// **`--` でオプションを終端する。** `rev-list` は pathspec も取るので、リポジトリ直下のエントリと
  /// 同名のブランチ（`docs` 等）では `ambiguous argument` で落ちる。cwd は main worktree の `root`
  /// なので、終端しないとその worktree だけ第0段が常に失敗し、黙って旧経路へ退行する。
  ///
  /// **`branchOrCommit` は曖昧さの無い名前で渡す**——ブランチは `refs/heads/<branch>` の完全 ref、
  /// detached は oid。短縮名は refs/tags が refs/heads より**先に**解決されるため、同名タグが
  /// あるとタグの指すコミットを判定してしまう（全経路——第0段 rev-list・cherry・
  /// `rev-parse ^{tree}`・merge-base——が同じ名前を受けるので、入口の 1 点で塞ぐ）。
  ///
  /// **素の `git cherry` 単独では multi-commit squash を検出できない。** cherry はコミット 1 個ずつの
  /// patch-id を比べるので、複数コミットを 1 個に畳んだ squash マージでは畳んだ側の patch-id が元のどの
  /// コミットとも一致せず「未取り込み」と誤判定する。そこでブランチの累積差分を 1 個のダングリング
  /// コミットへ合成してから再度 cherry にかける。**2 段構えが要る**——レシピ単独では、比較先の
  /// 厳密な祖先であるブランチ（＝完全に取り込み済み）に対して空パッチのダングリングコミットができ、
  /// 偽陽性で `+` を返す。第1段を全 target に先へ回すのは、後続 target が第1段（1 プロセス）で
  /// 立つとき第2段（4 プロセス）を省くため——空パッチの偽陽性が同じ target の第1段で防がれる構造は
  /// この順序でも不変。
  ///
  /// `unmerged` の `count` は到達不能数と patch 非等価数（成功した cherry の min）の **min**——
  /// どちらも「真に失われる数」の過大評価なので、min は厳密により良い過大評価（統合先が既定ブランチ
  /// でないリポジトリで「独自コミット +106」型の巨大数が実数へ縮む）。cherry が 1 本も成功しなければ
  /// nil——count を正直に言えないものを数値で語らない。
  ///
  /// `isolated` は呼び出し側が決める（`worktreeIsClean` と同じ理由）。この判定は比較先 T 本のとき
  /// worktree 1 本あたり最大 `1 + T×5` 本の git を撒く（到達性 1 本＋unmerged 経路は target ごとに
  /// cherry 系最大 5 本。merged 経路は is-ancestor 最大 T 本）ので、共有 read レーンに置くと直後の
  /// `addWorktree`(barrier) が全部の完了を待つ。
  func branchContainment(
    branchOrCommit: String, targets: [String], isolated: Bool = false,
    completion: @escaping (GitBranchContainment?) -> Void
  ) {
    let lane: GitRunner.Lane = isolated ? .independent : .read
    GitRunner.shared.run(
      ["rev-list", "--count", branchOrCommit, "--not", "--remotes=origin", "--"], cwd: root,
      lane: lane
    ) { output in
      // 第0段の失敗は nil に直結させない（到達性を諦めて従来の cherry 経路へ倒す）。
      let reachCount =
        output.isSuccess
        ? Int(output.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines)) : nil
      let probe = ContainmentProbe(
        branchOrCommit: branchOrCommit, reachCount: reachCount, lane: lane)
      if reachCount == 0 {
        // 安全事実（reachable）は証明済み。is-ancestor は「merged → <X>」を名乗れるかの
        // ラベルだけを決めるので、exit 1（非祖先）と異常失敗を区別せず汎用ラベル側へ倒してよい。
        // 比較先リスト順に試し、最初に tip を含んだ target を名乗る（既定優先）。
        self.firstAncestorTarget(probe, targets: targets[...]) { target in
          completion(.reachable(mergedInto: target))
        }
        return
      }
      self.cherryStage(probe, targets: targets[...], succeeded: [], completion: completion)
    }
  }

  /// 比較先リスト順に `merge-base --is-ancestor` を試し、最初に成功した target を返す（無ければ nil）。
  private func firstAncestorTarget(
    _ probe: ContainmentProbe, targets: ArraySlice<String>,
    completion: @escaping (String?) -> Void
  ) {
    guard let target = targets.first else {
      completion(nil)
      return
    }
    GitRunner.shared.run(
      ["merge-base", "--is-ancestor", probe.branchOrCommit, target], cwd: root, lane: probe.lane
    ) { output in
      guard output.isSuccess else {
        self.firstAncestorTarget(probe, targets: targets.dropFirst(), completion: completion)
        return
      }
      completion(target)
    }
  }

  /// 第1段（素の cherry）を比較先リスト順に回す。plus == 0 の target が見つかった時点で
  /// `.patchEquivalent(target:)`。cherry が失敗した target はスキップし、成功した target の plus 数を
  /// `succeeded` に積んで第2段へ渡す。remote が 1 つも無いリポジトリ（到達不能数＝全履歴）でも、
  /// ローカル既定ブランチとの比較で判定が立つ経路。
  private func cherryStage(
    _ probe: ContainmentProbe, targets: ArraySlice<String>,
    succeeded: [(target: String, plus: Int)],
    completion: @escaping (GitBranchContainment?) -> Void
  ) {
    guard let target = targets.first else {
      // 第1段では立たなかった。cherry が 1 本も成功しなければ count を語れないので nil。
      guard let plusMin = succeeded.map(\.plus).min() else {
        completion(nil)
        return
      }
      // 失われうる数は到達不能数と patch 非等価数の min（どちらも過大評価なので、より良い過大評価）。
      let count = probe.reachCount.map { min($0, plusMin) } ?? plusMin
      self.squashStage(
        probe, targets: succeeded.map(\.target)[...], count: count, completion: completion)
      return
    }
    GitRunner.shared.run(
      ["cherry", target, probe.branchOrCommit], cwd: root, lane: probe.lane
    ) { output in
      guard output.isSuccess else {
        self.cherryStage(
          probe, targets: targets.dropFirst(), succeeded: succeeded, completion: completion)
        return
      }
      let plus = output.stdoutText.split(separator: "\n").filter { $0.hasPrefix("+") }.count
      guard plus > 0 else {
        completion(.patchEquivalent(target: target))
        return
      }
      self.cherryStage(
        probe, targets: targets.dropFirst(), succeeded: succeeded + [(target, plus)],
        completion: completion)
    }
  }

  /// 第2段（squash 検出）を、**第1段の cherry が成功した** target について比較先リスト順に回す。
  /// merged が立った時点で `.patchEquivalent(target:)`。
  ///
  /// 立たなかった target は「確かめて非取り込み」と「確かめられなかった」を区別して畳む——
  /// `.unmerged` は「**どの比較先にも** patch 等価でない」という主張なので、1 本でも確かめられて
  /// いなければ名乗れない（`unresolved` が立っていたら nil）。cherry が 1 本も成功しなければ nil を
  /// 返す第1段と同じ流儀で、判定不能を「未取り込み」と断定しない。
  private func squashStage(
    _ probe: ContainmentProbe, targets: ArraySlice<String>, count: Int, unresolved: Bool = false,
    completion: @escaping (GitBranchContainment?) -> Void
  ) {
    guard let target = targets.first else {
      completion(unresolved ? nil : .unmerged(count: count))
      return
    }
    squashMergedCheck(probe, target: target) { merged in
      guard merged == true else {
        self.squashStage(
          probe, targets: targets.dropFirst(), count: count,
          unresolved: unresolved || merged == nil, completion: completion)
        return
      }
      completion(.patchEquivalent(target: target))
    }
  }

  /// ブランチの累積差分を合成したダングリングコミットで squash 取り込み済みかを見る。
  /// 判定できなければ nil。
  ///
  /// `commit-tree` は到達不可能なコミットオブジェクトを 1 個書くだけ（ref は触らず、いずれ gc で消える）。
  /// オブジェクトストアへの書き込みは git 自身が並行安全なので barrier に載せない。
  /// `-c user.name` / `-c user.email` は identity 自動推定が失敗する環境で `commit-tree` が落ちるのを
  /// 塞ぐためで、patch-id は内容だけから決まるため判定には影響しない。
  private func squashMergedCheck(
    _ probe: ContainmentProbe, target: String, completion: @escaping (Bool?) -> Void
  ) {
    GitRunner.shared.run(
      ["merge-base", target, probe.branchOrCommit], cwd: root, lane: probe.lane
    ) { base in
      guard base.isSuccess else {
        completion(nil)
        return
      }
      let mergeBase = base.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines)
      GitRunner.shared.run(
        ["rev-parse", "\(probe.branchOrCommit)^{tree}"], cwd: self.root, lane: probe.lane
      ) { tree in
        guard tree.isSuccess else {
          completion(nil)
          return
        }
        let treeOid = tree.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines)
        GitRunner.shared.run(
          [
            "-c", "user.name=orbe", "-c", "user.email=orbe@localhost",
            "commit-tree", treeOid, "-p", mergeBase, "-m", "_",
          ], cwd: self.root, lane: probe.lane
        ) { synthesized in
          guard synthesized.isSuccess else {
            completion(nil)
            return
          }
          let oid = synthesized.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines)
          GitRunner.shared.run(
            ["cherry", target, oid], cwd: self.root, lane: probe.lane
          ) { cherry in
            guard cherry.isSuccess else {
              completion(nil)
              return
            }
            completion(cherry.stdoutText.hasPrefix("-"))
          }
        }
      }
    }
  }
}
