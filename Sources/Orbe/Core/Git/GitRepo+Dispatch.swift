import Foundation

// MARK: - Dispatch（worktree/branch 列挙・worktree 作成）

extension GitRepo {
  /// リンク worktree を含む全チェックアウト（`git worktree list --porcelain`）。
  func worktrees(completion: @escaping ([GitWorktree]) -> Void) {
    runner.run(["worktree", "list", "--porcelain"], cwd: root) { output in
      completion(output.isSuccess ? WorktreeParser.parse(output.stdoutText) : [])
    }
  }

  /// ローカルブランチ（新しい順）。`worktreepath` 付きは既存 worktree 再利用の手がかりになる。
  func localBranches(completion: @escaping ([GitBranch]) -> Void) {
    runner.run(
      [
        "for-each-ref", "refs/heads", "--sort=-committerdate",
        "--format=%(refname:short)|%(committerdate:relative)|%(worktreepath)|%(upstream:short)"
          + "|%(upstream:track)",
      ], cwd: root
    ) { output in
      completion(output.isSuccess ? BranchParser.parseLocal(output.stdoutText) : [])
    }
  }

  /// リモート追跡ブランチ（新しい順・`origin/HEAD` ノイズは parser が除外）。
  func remoteBranches(completion: @escaping ([GitBranch]) -> Void) {
    runner.run(
      [
        "for-each-ref", "refs/remotes", "--sort=-committerdate",
        "--format=%(refname:short)|%(committerdate:relative)|%(authorname)",
      ], cwd: root
    ) { output in
      completion(output.isSuccess ? BranchParser.parseRemote(output.stdoutText) : [])
    }
  }

  /// origin から fetch し、削除された remote 追跡ブランチを prune する（`refs/remotes/origin/*` のみ更新）。
  /// 独立レーン（`.independent`）で走らせる: 数秒かかりうる fetch を GitRunner 共有 queue の barrier
  /// チェーンから切り離し、直後に Enter で来る書き込み（barrier）が in-flight fetch を待たないようにする
  /// （GCD barrier は submit 済み全ブロックの完了を待つため、共有 queue で走らせると `.read` でも Enter が
  /// 数秒ブロックされる）。並行安全: fetch が触るのは `refs/remotes/origin/*`、`addWorktree` が触るのは
  /// worktrees・HEAD・`refs/heads` で領域は概ね disjoint、git 自身の ref/index ロックで並行安全なため共有
  /// read-write lock の外で走らせてよい。`GIT_TERMINAL_PROMPT=0`（GitRunner 既定）で認証プロンプトはハングせず失敗に落ちる。
  func fetchPrune(completion: @escaping (Bool) -> Void) {
    runner.run(["fetch", "--prune", "origin"], cwd: root, lane: .independent) { output in
      completion(output.isSuccess)
    }
  }

  /// 既定ブランチ（issue の新規 worktree の base）。解決不能なら `main` へフォールバック。
  func defaultBranch(completion: @escaping (String) -> Void) {
    runner.run(
      ["symbolic-ref", "--short", "refs/remotes/origin/HEAD"], cwd: root
    ) { output in
      let name = output.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines)
      completion(output.isSuccess && !name.isEmpty ? name : "main")
    }
  }

  /// origin の URL が github.com を指すか（gh 不在でも判定できる cheap チェック）。
  func originIsGitHub(completion: @escaping (Bool) -> Void) {
    runner.run(["remote", "get-url", "origin"], cwd: root) { output in
      completion(output.isSuccess && output.stdoutText.contains("github.com"))
    }
  }

  /// URL からリポジトリを clone する。clone 前はリポジトリが無いため（`root` を持てず）static で持つ。
  /// `git clone --progress -- <url> <dest>`（cwd は dest の親）。成功なら nil、失敗なら理由。
  /// URL は正規化せず素通し（git が https / ssh / scp-like を native 解釈。`GIT_TERMINAL_PROMPT=0` で
  /// 資格情報プロンプトはハングせず stderr へ落ちる）。`--` は本ファイル他所と同じくオプション
  /// 終端の明示で、`-` 始まりの URL がフラグとして解釈される事故を塞ぐ。
  ///
  /// `--progress`: GUI から起動した git は stderr が tty でないため既定で進捗を出さない。進捗が
  /// 出ないと「無出力＝ハング」と読まれて正常な大規模 clone が打ち切られるので、明示的に出させる。
  ///
  /// 独立レーン: 新規ディレクトリを作るだけで既存リポジトリの index・作業ツリー・ref に一切
  /// 触れない（共有状態はゼロ）。所要時間はネットワークとリポジトリ規模しだいで分単位になり得るので、
  /// barrier に置くと無関係な操作まで巻き添えにする。
  static func clone(
    url: String, dest: String, runner: GitRunner = .shared,
    completion: @escaping (GitFailure?) -> Void
  ) {
    let parent = (dest as NSString).deletingLastPathComponent
    let args = ["clone", "--progress", "--", url, dest]
    runner.run(args, cwd: parent, lane: .independent) { output in
      guard !output.isSuccess else {
        completion(nil)
        return
      }
      completion(failure(from: output))
    }
  }

  /// worktree を追加する（現在の作業ツリーは一切変更しない・隔離された新規ディレクトリを作る）。
  /// `git worktree add [-b <newBranch>] [--track] <path> <base>`。成功なら nil、失敗なら理由。
  ///
  /// 独立レーン: 触るのは新規ディレクトリ・`$GIT_COMMON_DIR/worktrees/<名前>`・`-b` 指定時の
  /// `refs/heads/<新ブランチ>` だけで、**呼び出し元チェックアウトの index には触らない**。barrier が
  /// 守っていた不変条件（同一チェックアウトの `.git/index.lock` を奪い合わない）は壊れない。ref は
  /// git 自身が `<ref>.lock` で守る。post-checkout hook はユーザーのコードで所要時間に上限が無いため、
  /// barrier に置くと 1 本のハングが以後の全 git 操作を止める。
  func addWorktree(
    path: String, base: String, newBranch: String?, track: Bool,
    completion: @escaping (GitFailure?) -> Void
  ) {
    var args = ["worktree", "add"]
    if let newBranch { args += ["-b", newBranch] }
    if track { args.append("--track") }
    args += [path, base]
    runner.run(args, cwd: root, lane: .independent) { output in
      guard !output.isSuccess else {
        completion(nil)
        return
      }
      // post-checkout hook は worktree が出来上がった**後**に走る。hook が返らず打ち切った場合、
      // worktree 自体は完成している。失敗として返すと、実在する worktree を指したまま再実行が
      // `fatal: a branch named 'x' already exists` で詰む——直した数より多く壊す。実体があるなら成功。
      if output.timedOut, GitRepo.worktreeIsPresent(at: path) {
        completion(nil)
        return
      }
      completion(GitRepo.failure(from: output))
    }
  }

  /// リンク worktree の実体（`<path>/.git` はリンク先を書いたファイル）。
  private static func worktreeIsPresent(at path: String) -> Bool {
    FileManager.default.fileExists(atPath: (path as NSString).appendingPathComponent(".git"))
  }

  /// 失敗した実行を理由へ写す。打ち切りは git が何も言い残していないので、stderr でなく `.timedOut`。
  private static func failure(from output: GitRunner.Output) -> GitFailure {
    output.timedOut ? .timedOut : .message(essentialFailureReason(output.stderrText))
  }

  /// git の stderr から実質的な失敗理由を取り出す。成功・失敗どちらでも出る進捗風の行
  /// （`Preparing worktree (new branch 'issue/44')`・`--progress` の `Receiving objects: 42%`）を落とし、
  /// `fatal:`／`error:` 行（複数あれば全て・改行結合）を返す。無ければ最終非空行、それも無ければ stderr 全文。
  /// **`\r` でも行を割る**——`--progress` の進捗は `\r` 区切りで流れるので、`\n` だけで割ると進捗と
  /// `fatal:` が 1 行に融合して巨大な失敗理由になる。git stderr の癖はこの git ラッパー層に閉じる
  /// （`BranchParser` 等と同じく、git の出力を読む規則としてここに置く）。
  static func essentialFailureReason(_ stderr: String) -> String {
    let lines =
      stderr
      .split(omittingEmptySubsequences: false, whereSeparator: { $0 == "\n" || $0 == "\r" })
      .map { $0.trimmingCharacters(in: .whitespaces) }
      .filter { !$0.isEmpty }
    let reasons = lines.filter { $0.contains("fatal:") || $0.contains("error:") }
    if !reasons.isEmpty { return reasons.joined(separator: "\n") }
    return lines.last ?? stderr
  }
}
