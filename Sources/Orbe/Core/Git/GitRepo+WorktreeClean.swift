import Foundation

// MARK: - worktree の掃除（安全確認・削除）

extension GitRepo {
  /// 作業ツリーが clean か（`status --porcelain` が空）。
  ///
  /// `--ignore-submodules=none` を明示するのは、ユーザーの `diff.ignoreSubmodules` 設定で submodule 内の
  /// 変更が status から消えることがあり、それを「clean」と誤認すると削除の前提が崩れるため。
  /// git 自体が失敗したら「確認できなかった」＝clean でない側に倒す。
  func worktreeIsClean(at path: String, completion: @escaping (Bool) -> Void) {
    // 実体が消えた worktree でも起動できるよう、cwd は main worktree に置いて `-C` で対象を指す。
    GitRunner.shared.run(
      ["-C", path, "status", "--porcelain", "--ignore-submodules=none"], cwd: root
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
  /// オブジェクトストアへの書き込みは git 自身が並行安全なので read レーンで走らせる（barrier に載せると
  /// 直後の決定を待たせる）。`-c user.name` / `-c user.email` は identity 自動推定が失敗する環境で
  /// `commit-tree` が落ちるのを塞ぐためで、patch-id は内容だけから決まるため判定には影響しない。
  func unmergedCommitCount(
    branchOrCommit: String, default defaultBranch: String,
    completion: @escaping (Int?) -> Void
  ) {
    GitRunner.shared.run(["cherry", defaultBranch, branchOrCommit], cwd: root) { output in
      guard output.isSuccess else {
        completion(nil)
        return
      }
      let plus = output.stdoutText.split(separator: "\n").filter { $0.hasPrefix("+") }.count
      guard plus > 0 else {
        completion(0)
        return
      }
      self.squashMergedCheck(branchOrCommit, default: defaultBranch) { merged in
        completion(merged.map { $0 ? 0 : plus })
      }
    }
  }

  /// ブランチの累積差分を合成したダングリングコミットで squash 取り込み済みかを見る。
  /// 判定できなければ nil。
  private func squashMergedCheck(
    _ branchOrCommit: String, default defaultBranch: String,
    completion: @escaping (Bool?) -> Void
  ) {
    GitRunner.shared.run(["merge-base", defaultBranch, branchOrCommit], cwd: root) { base in
      guard base.isSuccess else {
        completion(nil)
        return
      }
      let mergeBase = base.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines)
      GitRunner.shared.run(["rev-parse", "\(branchOrCommit)^{tree}"], cwd: self.root) { tree in
        guard tree.isSuccess else {
          completion(nil)
          return
        }
        let treeOid = tree.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines)
        GitRunner.shared.run(
          [
            "-c", "user.name=orbe", "-c", "user.email=orbe@localhost",
            "commit-tree", treeOid, "-p", mergeBase, "-m", "_",
          ], cwd: self.root
        ) { synthesized in
          guard synthesized.isSuccess else {
            completion(nil)
            return
          }
          let oid = synthesized.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines)
          GitRunner.shared.run(["cherry", defaultBranch, oid], cwd: self.root) { cherry in
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
  /// `--force` 1 個が外すのは「dirty」と「submodule」の 2 つで、dirty は呼び出し側が削除の直前に
  /// status で検証済み、submodule は消えるのが作業コピーだけで実体は common dir に残る。
  /// locked は `-f` 1 個では外れないため、locked な worktree はそもそも安全確認を通さない。
  func removeWorktree(path: String, completion: @escaping (String?) -> Void) {
    GitRunner.shared.run(
      ["worktree", "remove", "--force", path], cwd: root, write: true
    ) { output in
      completion(output.isSuccess ? nil : GitRepo.essentialFailureReason(output.stderrText))
    }
  }

  /// ローカルブランチを削除する。成功なら nil、失敗なら実質的な失敗理由。
  ///
  /// `-d` ではなく `-D` を直接呼ぶ。safe 行は `unmergedCommitCount == 0`（内容が既定ブランチに
  /// patch 等価で存在する）を通っており、これは `-d` の到達性判定より厳密に強い——`-d` は squash も
  /// rebase も取りこぼすので、先に試しても safe 行ですら通らない。caution 行から呼ばれる場合は、
  /// ユーザーが行ごとに `worktree + ブランチ` を選ぶ行為そのものが安全確認の上書きになっている。
  func deleteBranch(name: String, completion: @escaping (String?) -> Void) {
    GitRunner.shared.run(["branch", "-D", name], cwd: root, write: true) { output in
      completion(output.isSuccess ? nil : GitRepo.essentialFailureReason(output.stderrText))
    }
  }
}
