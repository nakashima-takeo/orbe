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
    // 止まった操作を先に見る——rebase の途中は HEAD が detached で upstream も無いので、逆の順では「upstream が無い」に化ける。
    let before = GitWorktreeOperationProbe.detect(worktreeAt: root)
    if case .inProgress(let operation) = before {
      return Self.fail(.operationInProgress(operation), completion)
    }
    if let branch, branch.name == nil { return Self.fail(.detached, completion) }
    if let branch, branch.upstream == nil { return Self.fail(.noUpstream, completion) }
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
      ) { output in completion(Self.pushFailure(output)) }
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

  /// push の失敗。送れなかった ref は `--porcelain` の `!` 行（`!\t<from>:<to>\t<要約>`）に出る——`[rejected]`
  /// （fetch first・non-fast-forward）は「拒否された」。それ以外（サーバの hook が断った `[remote rejected]` 等）は
  /// 「その他」で、要約を理由の頭に置く。`--porcelain` では要約が stdout へ移り、stderr には「failed to push some refs」
  /// しか残らないため。
  static func pushFailure(_ output: GitRunner.Output) -> GitWriteFailure? {
    let failure = GitWriteFailure.ofRemote(output)
    guard case .reason(let reason) = failure else { return failure }
    let refused = output.stdoutText.split(separator: "\n").compactMap { line -> (String, String)? in
      let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
      guard fields.count == 3, fields[0] == "!" else { return nil }
      return (String(fields[1].split(separator: ":").last ?? fields[1]), String(fields[2]))
    }
    if refused.contains(where: { $0.1.hasPrefix("[rejected]") }) { return .pushRejected }
    return .reason((refused.map { "\($0.0) \($0.1)" } + [reason]).joined(separator: "\n"))
  }

  private static func fail(
    _ failure: GitWriteFailure, _ completion: @escaping (GitWriteFailure?) -> Void
  ) {
    DispatchQueue.main.async { completion(failure) }
  }
}
