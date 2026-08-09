import Foundation

// MARK: - worktree の掃除（安全確認・削除）

extension GitRepo {
  /// 作業ツリーが clean か（`status --porcelain` が空）。
  ///
  /// この bool は `--force` 削除を止める唯一の関門なので、**status の見え方を左右するユーザー設定を
  /// すべて引数で上書きして事実を固定する**。`--ignore-submodules=none` は `diff.ignoreSubmodules` を、
  /// `--untracked-files=normal` は `status.showUntrackedFiles`（巨大リポの高速化として広く使われ、
  /// `no` だと未追跡ファイルだけの worktree が空出力＝clean に見える）を封じる。`--no-optional-locks` は
  /// 観測でユーザーが作業中の worktree の index を書き換えないため（`GitRepo.snapshot` と同じ作法）。
  /// git 自体が失敗したら「確認できなかった」＝clean でない側に倒す。
  ///
  /// `isolated` は呼び出し側が決める: 分類のプローブは共有 read-write lock の外へ逃がして直後の
  /// Enter(barrier) を待たせないが、削除直前のゲートは lock の中に置き実行と同じレーンで直列させる。
  func worktreeIsClean(
    at path: String, isolated: Bool = false, completion: @escaping (Bool) -> Void
  ) {
    // 実体が消えた worktree でも起動できるよう、cwd は main worktree に置いて `-C` で対象を指す。
    GitRunner.shared.run(
      [
        "--no-optional-locks", "-C", path, "status", "--porcelain",
        "--untracked-files=normal", "--ignore-submodules=none",
      ], cwd: root, isolated: isolated
    ) { output in
      completion(
        output.isSuccess
          && output.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }
  }

  /// 既定ブランチに取り込まれていない独自コミットの件数。取り込み済みなら 0、判定できなければ nil。
  ///
  /// **素の `git cherry` 単独では multi-commit squash を検出できない。** cherry はコミット 1 個ずつの
  /// patch-id を比べるので、複数コミットを 1 個に畳んだ squash マージでは畳んだ側の patch-id が元のどの
  /// コミットとも一致せず「未取り込み」と誤判定する。そこでブランチの累積差分を 1 個のダングリング
  /// コミットへ合成してから再度 cherry にかける。**2 段構えが要る**——レシピ単独では、既定ブランチの
  /// 厳密な祖先であるブランチ（＝完全に取り込み済み）に対して空パッチのダングリングコミットができ、
  /// 偽陽性で `+` を返す。
  ///
  /// `commit-tree` は到達不可能なコミットオブジェクトを 1 個書くだけ（ref は触らず、いずれ gc で消える）。
  /// オブジェクトストアへの書き込みは git 自身が並行安全なので barrier に載せない。
  /// `-c user.name` / `-c user.email` は identity 自動推定が失敗する環境で `commit-tree` が落ちるのを
  /// 塞ぐためで、patch-id は内容だけから決まるため判定には影響しない。
  ///
  /// `isolated` は呼び出し側が決める（`worktreeIsClean` と同じ理由）。この判定は worktree 1 本あたり
  /// 最大 5 本の git を撒くので、共有 read レーンに置くと直後の `addWorktree`(barrier) が全部の完了を待つ。
  func unmergedCommitCount(
    branchOrCommit: String, default defaultBranch: String, isolated: Bool = false,
    completion: @escaping (Int?) -> Void
  ) {
    let args = ["cherry", defaultBranch, branchOrCommit]
    GitRunner.shared.run(args, cwd: root, isolated: isolated) { output in
      guard output.isSuccess else {
        completion(nil)
        return
      }
      let plus = output.stdoutText.split(separator: "\n").filter { $0.hasPrefix("+") }.count
      guard plus > 0 else {
        completion(0)
        return
      }
      self.squashMergedCheck(branchOrCommit, default: defaultBranch, isolated: isolated) { merged in
        completion(merged.map { $0 ? 0 : plus })
      }
    }
  }

  /// ブランチの累積差分を合成したダングリングコミットで squash 取り込み済みかを見る。
  /// 判定できなければ nil。
  private func squashMergedCheck(
    _ branchOrCommit: String, default defaultBranch: String, isolated: Bool,
    completion: @escaping (Bool?) -> Void
  ) {
    GitRunner.shared.run(
      ["merge-base", defaultBranch, branchOrCommit], cwd: root, isolated: isolated
    ) { base in
      guard base.isSuccess else {
        completion(nil)
        return
      }
      let mergeBase = base.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines)
      GitRunner.shared.run(
        ["rev-parse", "\(branchOrCommit)^{tree}"], cwd: self.root, isolated: isolated
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
          ], cwd: self.root, isolated: isolated
        ) { synthesized in
          guard synthesized.isSuccess else {
            completion(nil)
            return
          }
          let oid = synthesized.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines)
          GitRunner.shared.run(
            ["cherry", defaultBranch, oid], cwd: self.root, isolated: isolated
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

  /// worktree を削除する。成功なら nil、失敗なら実質的な失敗理由。
  ///
  /// **`--force` は検証済みの前提のもとでの唯一正しい呼び方であって、未知の拒否を握り潰す逃げではない。**
  /// submodule を初期化した worktree を、git は作業ツリーが完全に clean でも
  /// `git worktree remove` で消させない（`submodule deinit` して実体を空にしても拒否は変わらない）。
  /// Orbe 自身のリポジトリも submodule を持つため、`--force` 以外の道が無い。
  /// `--force` 1 個が外すのは「dirty」と「submodule」の 2 つ。dirty は呼び出し側が削除の直前に
  /// status で検証済み。submodule は作業コピーと**その worktree 固有の submodule gitdir
  /// （`<common>/worktrees/<id>/modules/…`。common dir 直下ではなく、alternates も持たない独立の
  /// オブジェクトストア）ごと消える**——safe 行は super のブランチが既定ブランチへ取り込み済みである
  /// ことを通っており、その前提のもとで submodule 側にだけ未 push が残る状態は成立しない。
  /// locked は `-f` 1 個では外れないため、locked な worktree はそもそも安全確認を通さない。
  func removeWorktree(path: String, completion: @escaping (String?) -> Void) {
    GitRunner.shared.run(
      ["worktree", "remove", "--force", path], cwd: root, write: true
    ) { output in
      completion(output.isSuccess ? nil : GitRepo.essentialFailureReason(output.stderrText))
    }
  }

  /// ローカルブランチを、`expectedOid` の先端であることを条件に削除する。
  /// 成功なら nil、失敗なら実質的な失敗理由。
  ///
  /// `branch -D` ではなく `update-ref -d <ref> <oid>` を呼ぶ。`-D` は無条件削除なので、判定した時点の
  /// 先端と削除する時点の先端がずれていても気づけない——**worktree を消して失うのは作業コピーだが、
  /// ブランチを消して失うのはコミットそのもの**（reflog も同時に消え、通常は `fsck --lost-found` しか
  /// 残らない）で、判定は clean 画面を開いた時点で凍結される。`update-ref` の第 3 引数は
  /// 「この OID のときだけ」という compare-and-swap で、ref ロックの中で比較と削除が起きるため
  /// 読み直して比べる 2 段と違い窓が無い。分類後に外部からコミットが載ったブランチは
  /// `cannot lock ref … but expected …` で拒否され、失敗行として集約される。
  ///
  /// 到達性判定（`branch -d`）に頼らない点は変わらない: safe 行は `unmergedCommitCount == 0`
  /// （内容が既定ブランチに patch 等価で存在する）を通っており、これは `-d` より厳密に強い——
  /// `-d` は squash も rebase も取りこぼすので、先に試しても safe 行ですら通らない。caution 行から
  /// 呼ばれる場合は、ユーザーが行ごとに `worktree + ブランチ` を選ぶ行為が安全確認の上書きになっている。
  func deleteBranch(name: String, expectedOid: String, completion: @escaping (String?) -> Void) {
    GitRunner.shared.run(
      ["update-ref", "-d", "refs/heads/\(name)", expectedOid], cwd: root, write: true
    ) { output in
      completion(output.isSuccess ? nil : GitRepo.essentialFailureReason(output.stderrText))
    }
  }
}
