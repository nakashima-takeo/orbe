import Foundation

// MARK: - Dispatch（worktree/branch 列挙・worktree 作成）

extension GitRepo {
  /// リンク worktree を含む全チェックアウト（`git worktree list --porcelain`）。
  func worktrees(completion: @escaping ([GitWorktree]) -> Void) {
    GitRunner.shared.run(["worktree", "list", "--porcelain"], cwd: root) { output in
      completion(output.isSuccess ? WorktreeParser.parse(output.stdoutText) : [])
    }
  }

  /// ローカルブランチ（新しい順）。`worktreepath` 付きは既存 worktree 再利用の手がかりになる。
  func localBranches(completion: @escaping ([GitBranch]) -> Void) {
    GitRunner.shared.run(
      [
        "for-each-ref", "refs/heads", "--sort=-committerdate",
        "--format=%(refname:short)|%(committerdate:relative)|%(worktreepath)|%(upstream:short)",
      ], cwd: root
    ) { output in
      completion(output.isSuccess ? BranchParser.parseLocal(output.stdoutText) : [])
    }
  }

  /// リモート追跡ブランチ（新しい順・`origin/HEAD` ノイズは parser が除外）。
  func remoteBranches(completion: @escaping ([GitBranch]) -> Void) {
    GitRunner.shared.run(
      [
        "for-each-ref", "refs/remotes", "--sort=-committerdate",
        "--format=%(refname:short)|%(committerdate:relative)|%(authorname)",
      ], cwd: root
    ) { output in
      completion(output.isSuccess ? BranchParser.parseRemote(output.stdoutText) : [])
    }
  }

  /// origin から fetch し、削除された remote 追跡ブランチを prune する（`refs/remotes/origin/*` のみ更新）。
  /// 独立レーン（`isolated: true`）で走らせる: 数秒かかりうる fetch を GitRunner 共有 queue の barrier
  /// チェーンから切り離し、直後に Enter で来る `addWorktree`(barrier) が in-flight fetch を待たないようにする
  /// （GCD barrier は submit 済み全ブロックの完了を待つため、共有 queue で走らせると write:false でも Enter が
  /// 数秒ブロックされる）。並行安全: fetch が触るのは `refs/remotes/origin/*`、`addWorktree` が触るのは
  /// worktrees・HEAD・`refs/heads` で領域は概ね disjoint、git 自身の ref/index ロックで並行安全なため共有
  /// read-write lock の外で走らせてよい。`GIT_TERMINAL_PROMPT=0`（GitRunner 既定）で認証プロンプトはハングせず失敗に落ちる。
  func fetchPrune(completion: @escaping (Bool) -> Void) {
    GitRunner.shared.run(["fetch", "--prune", "origin"], cwd: root, isolated: true) { output in
      completion(output.isSuccess)
    }
  }

  /// 既定ブランチ（issue の新規 worktree の base）。解決不能なら `main` へフォールバック。
  func defaultBranch(completion: @escaping (String) -> Void) {
    GitRunner.shared.run(
      ["symbolic-ref", "--short", "refs/remotes/origin/HEAD"], cwd: root
    ) { output in
      let name = output.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines)
      completion(output.isSuccess && !name.isEmpty ? name : "main")
    }
  }

  /// origin の URL が github.com を指すか（gh 不在でも判定できる cheap チェック）。
  func originIsGitHub(completion: @escaping (Bool) -> Void) {
    GitRunner.shared.run(["remote", "get-url", "origin"], cwd: root) { output in
      completion(output.isSuccess && output.stdoutText.contains("github.com"))
    }
  }

  /// URL からリポジトリを clone する。clone 前はリポジトリが無いため（`root` を持てず）static で持つ。
  /// `git clone -- <url> <dest>`（cwd は dest の親）。成功なら nil、失敗なら stderr（`addWorktree` と同契約）。
  /// URL は正規化せず素通し（git が https / ssh / scp-like を native 解釈。`GIT_TERMINAL_PROMPT=0` で
  /// 資格情報プロンプトはハングせず stderr へ落ちる）。`--` は本ファイル他所と同じくオプション
  /// 終端の明示で、`-` 始まりの URL がフラグとして解釈される事故を塞ぐ。
  static func clone(url: String, dest: String, completion: @escaping (String?) -> Void) {
    let parent = (dest as NSString).deletingLastPathComponent
    GitRunner.shared.run(["clone", "--", url, dest], cwd: parent, write: true) { output in
      completion(output.isSuccess ? nil : output.stderrText)
    }
  }

  /// worktree を追加する（現在の作業ツリーは一切変更しない・隔離された新規ディレクトリを作る）。
  /// `git worktree add [-b <newBranch>] [--track] <path> <base>`。成功なら nil、失敗なら実質的な失敗理由。
  func addWorktree(
    path: String, base: String, newBranch: String?, track: Bool,
    completion: @escaping (String?) -> Void
  ) {
    var args = ["worktree", "add"]
    if let newBranch { args += ["-b", newBranch] }
    if track { args.append("--track") }
    args += [path, base]
    GitRunner.shared.run(args, cwd: root, write: true) { output in
      completion(output.isSuccess ? nil : GitRepo.essentialFailureReason(output.stderrText))
    }
  }

  /// `git worktree add` の stderr から実質的な失敗理由を取り出す。成功・失敗どちらでも先頭に出る進捗風
  /// `Preparing worktree (new branch 'issue/44')` を落とし、`fatal:`／`error:` 行（複数あれば全て・改行結合）
  /// を返す。無ければ最終非空行、それも無ければ stderr 全文。git stderr の癖はこの git ラッパー層に閉じる。
  private static func essentialFailureReason(_ stderr: String) -> String {
    let lines = stderr.split(separator: "\n", omittingEmptySubsequences: false)
      .map { $0.trimmingCharacters(in: .whitespaces) }
      .filter { !$0.isEmpty }
    let reasons = lines.filter { $0.contains("fatal:") || $0.contains("error:") }
    if !reasons.isEmpty { return reasons.joined(separator: "\n") }
    return lines.last ?? stderr
  }
}
