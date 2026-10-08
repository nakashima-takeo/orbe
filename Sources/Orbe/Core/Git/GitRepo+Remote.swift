import Foundation

// MARK: - リモートとの書き込み（fetch・pull・push）

/// 利用者が起こすリモートとの書き込み。無出力で打ち切らず `handle` で止め、進捗（git の語の行）を `onProgress` へ
/// 届いた順に渡す。ユーザーの設定（既定の remote・prune・`pull.rebase`・`push.default`・`pushRemote`・
/// `core.sshCommand`・credential helper）はそのまま効く。completion は main で返る。
///
/// 前提（upstream・detached・origin・止まった操作）は git を起こす前に型で判定する。`branch` は呼んだ時点の status の
/// ブランチで、nil（分からない）なら判定を飛ばして git に任せる。
extension GitRepo {
  func fetch(
    onProgress: @escaping (String) -> Void, handle: GitRunner.Handle,
    completion: @escaping (GitWriteFailure?) -> Void
  ) {
    runner.run(
      ["fetch", "--progress"], cwd: root, timesOut: false, onProgress: onProgress, handle: handle
    ) { completion(.ofRemote($0)) }
  }

  /// 取り込む。merge か rebase かはユーザーの設定のまま。競合で止まったかは、pull の前に無かった止まった操作が
  /// 後に在るかで読む（stderr の字面で読まない）。
  func pull(
    branch: GitStatus.Branch?, onProgress: @escaping (String) -> Void, handle: GitRunner.Handle,
    completion: @escaping (GitWriteFailure?) -> Void
  ) {
    if let branch, branch.upstream == nil { return Self.fail(.noUpstream, completion) }
    let before = GitWorktreeOperationProbe.detect(worktreeAt: root)
    if case .inProgress(let operation) = before {
      return Self.fail(.operationInProgress(operation), completion)
    }
    runner.run(
      ["pull", "--progress"], cwd: root, timesOut: false, onProgress: onProgress, handle: handle
    ) { output in
      let failure = GitWriteFailure.ofRemote(output)
      if failure != nil, failure != .cancelled, before == .none,
        case .inProgress(let operation) = GitWorktreeOperationProbe.detect(worktreeAt: self.root)
      {
        completion(.conflicted(operation))
        return
      }
      completion(failure)
    }
  }

  /// 送る。upstream があれば `git push` をユーザーの設定のまま走らせ、無ければ origin へ upstream を付けて出す
  /// （`-u origin HEAD`——名前と付け先は実行時の HEAD から git が決めるので、status が古くても別のブランチを送らない）。
  /// 拒否は `--porcelain` の機械向けの行で読む。
  func push(
    branch: GitStatus.Branch?, onProgress: @escaping (String) -> Void, handle: GitRunner.Handle,
    completion: @escaping (GitWriteFailure?) -> Void
  ) {
    func run(_ extra: [String]) {
      runner.run(
        ["push", "--porcelain", "--progress"] + extra, cwd: root, timesOut: false,
        onProgress: onProgress, handle: handle
      ) { output in
        guard !Self.pushWasRejected(output) else { return completion(.pushRejected) }
        completion(.ofRemote(output))
      }
    }
    guard let branch, branch.upstream == nil else { return run([]) }
    guard branch.name != nil else { return Self.fail(.detached, completion) }
    runner.run(["remote"], cwd: root, handle: handle) { listed in
      if let failure = GitWriteFailure.of(listed) { return completion(failure) }
      guard listed.stdoutText.split(separator: "\n").contains("origin") else {
        return completion(.noPushDestination)
      }
      run(["-u", "origin", "HEAD"])
    }
  }

  /// `--porcelain` の `!` 行（送れなかった ref）が `[rejected]`（fetch first・non-fast-forward）か。
  /// `[remote rejected]`（サーバの hook 等）はその理由のまま「その他」。
  static func pushWasRejected(_ output: GitRunner.Output) -> Bool {
    !output.isSuccess
      && output.stdoutText.split(separator: "\n").contains {
        $0.hasPrefix("!") && $0.contains("\t[rejected]")
      }
  }

  private static func fail(
    _ failure: GitWriteFailure, _ completion: @escaping (GitWriteFailure?) -> Void
  ) {
    DispatchQueue.main.async { completion(failure) }
  }
}
