import Foundation

// MARK: - 変更の書き込み（ステージ・解除・破棄・コミット・取り消し）

/// 利用者が起こす index・作業ツリー・HEAD への書き込み。どれも無出力で打ち切らず、`handle` で止める（hook・filter・
/// 署名の沈黙は「何も起きていない」ことを意味しない）。順番は呼び出し側（根のサービス）が作る——同じ worktree の
/// index へ同時に書けば、git は index.lock で待たずに落ちる。completion は main で返る。
///
/// パスはファイル名そのもの（ユーザーのデータ）なので、NUL 区切りの標準入力で渡し、その呼び出しだけ pathspec を
/// literal にする（`*` `:` を含む名前で別のファイルに当たらない。引数の長さの上限も越えない）。
extension GitRepo {
  /// パスをステージする（変更・削除・未追跡のどれでも、作業ツリーの姿を index へ）。
  func stage(
    paths: [String], handle: GitRunner.Handle, completion: @escaping (GitWriteFailure?) -> Void
  ) {
    guard !paths.isEmpty else { return Self.succeed(completion) }
    runOnPaths(["add", "-A"], paths: paths, handle: handle) { completion(.of($0)) }
  }

  /// パスのステージを解く（index を HEAD の版へ。初回コミット前なら index から外す）。`restore --staged` は HEAD が
  /// 無いと落ちるので `reset` を使う。
  func unstage(
    paths: [String], handle: GitRunner.Handle, completion: @escaping (GitWriteFailure?) -> Void
  ) {
    guard !paths.isEmpty else { return Self.succeed(completion) }
    runOnPaths(["reset", "-q"], paths: paths, handle: handle) { completion(.of($0)) }
  }

  /// パスの変更を捨てる。追跡中のパスは作業ツリーを index の版へ戻し（ステージ済みの分は残る）、未追跡のパスは
  /// ゴミ箱へ移す（元に戻せる）。どちらでもなく実体も無いパス（rename の元パス）は何もしない。
  ///
  /// 追跡中かは呼んだ時点の index で決める（観測の status は古いことがあり、それを信じて追跡中のファイルを
  /// ゴミ箱へ送らない）。index は丸ごと読む——`ls-files` はパスを標準入力で受けられず、引数では長さの上限を越えうる。
  /// ゴミ箱へ移せなければ失敗で返し、消さない。
  func discard(
    paths: [String], handle: GitRunner.Handle, completion: @escaping (GitWriteFailure?) -> Void
  ) {
    guard !paths.isEmpty else { return Self.succeed(completion) }
    let asked = Set(paths)
    runner.run(
      ["ls-files", "-z"], cwd: root, handle: handle,
      transform: { listed -> (GitRunner.Output, Set<String>) in
        let tracked = listed.stdout.split(separator: 0)
          .compactMap { String(bytes: $0, encoding: .utf8) }.filter(asked.contains)
        return (listed, Set(tracked))
      },
      completion: { listed, tracked in
        if let failure = GitWriteFailure.of(listed) {
          completion(failure)
          return
        }
        let restore = paths.filter { tracked.contains($0) }
        let trash = paths.filter { !tracked.contains($0) && self.exists($0) }
        let moveToTrash = {
          do {
            for path in trash {
              try Self.moveToTrash(self.url(of: path))
            }
            completion(nil)
          } catch {
            completion(.reason(error.localizedDescription))
          }
        }
        guard !restore.isEmpty else {
          moveToTrash()
          return
        }
        self.runOnPaths(["restore", "--worktree"], paths: restore, handle: handle) { restored in
          if let failure = GitWriteFailure.of(restored) {
            completion(failure)
            return
          }
          moveToTrash()
        }
      })
  }

  /// ステージ済みの分をコミットする。メッセージは書いたまま残る（`#` 始まりの行も。前後の空行・行末の空白・続く空行だけ
  /// 整える）。`amend` は直前のコミットを差し替え、メッセージが空なら前のメッセージを一字も変えずに中身だけ差し替える
  /// ——整え方を明示しないと、利用者の `commit.cleanup=strip` が前のメッセージの `#` の行を消す。ユーザーの hook・署名の
  /// 設定はそのまま効く。
  func commit(
    message: String, amend: Bool, handle: GitRunner.Handle,
    completion: @escaping (GitWriteFailure?) -> Void
  ) {
    let keepsMessage = amend && message.allSatisfy(\.isWhitespace)
    var args = ["commit"] + (amend ? ["--amend"] : [])
    args +=
      keepsMessage ? ["--no-edit", "--cleanup=verbatim"] : ["--cleanup=whitespace", "-F", "-"]
    runner.run(
      args, cwd: root, stdin: keepsMessage ? nil : Data(message.utf8), timesOut: false,
      handle: handle
    ) { completion(.of($0)) }
  }

  /// 最後のコミットを取り消す。HEAD が 1 つ戻り、中身はステージ済みに残る。初回コミットなら、HEAD のブランチの ref を
  /// 消して初回コミット前へ戻す（index はそのまま＝全部ステージ済み）。
  func undoLastCommit(handle: GitRunner.Handle, completion: @escaping (GitWriteFailure?) -> Void) {
    let parents = ["rev-list", "--parents", "-n", "1", "HEAD"]
    runner.run(parents, cwd: root, handle: handle) { listed in
      if let failure = GitWriteFailure.of(listed) {
        completion(failure)
        return
      }
      let commits = listed.stdoutText.split(whereSeparator: \.isWhitespace).map(String.init)
      guard let head = commits.first else {
        completion(.reason(GitRepo.failureReason(of: listed)))
        return
      }
      guard commits.count == 1 else {
        self.runner.run(
          ["reset", "--soft", "HEAD~1"], cwd: self.root, timesOut: false, handle: handle
        ) { completion(.of($0)) }
        return
      }
      self.runner.run(["symbolic-ref", "-q", "HEAD"], cwd: self.root, handle: handle) { ref in
        guard ref.isSuccess else {
          completion(ref.exited && ref.status == 1 ? .detached : .of(ref))
          return
        }
        let branch = ref.stdoutText.trimmingCharacters(in: .newlines)
        self.runner.run(
          ["update-ref", "-d", branch, head], cwd: self.root, timesOut: false, handle: handle
        ) { completion(.of($0)) }
      }
    }
  }

  /// ゴミ箱の行き先の差し替え（テスト用。隔離ハーネスが毎テスト caseDir の下へ張る）。nil なら利用者のゴミ箱。
  nonisolated(unsafe) static var trashDirectoryOverride: URL?

  private static func moveToTrash(_ url: URL) throws {
    guard let directory = trashDirectoryOverride else {
      try FileManager.default.trashItem(at: url, resultingItemURL: nil)
      return
    }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try FileManager.default.moveItem(
      at: url, to: directory.appendingPathComponent(url.lastPathComponent))
  }

  /// 空のパスの操作は git を起こさずに成功で返す——パスの無い `add -A`・`reset` は全体に効いてしまう。
  private static func succeed(_ completion: @escaping (GitWriteFailure?) -> Void) {
    DispatchQueue.main.async { completion(nil) }
  }

  private func runOnPaths(
    _ args: [String], paths: [String], handle: GitRunner.Handle,
    completion: @escaping (GitRunner.Output) -> Void
  ) {
    let list = paths.map { $0 + "\0" }.joined()
    runner.run(
      args + ["--pathspec-from-file=-", "--pathspec-file-nul"], cwd: root, stdin: Data(list.utf8),
      environment: ["GIT_LITERAL_PATHSPECS": "1"], timesOut: false, handle: handle,
      completion: completion)
  }

  private func url(of relativePath: String) -> URL {
    URL(fileURLWithPath: root).appendingPathComponent(relativePath)
  }

  /// symlink を辿らずに在るか（壊れた symlink も在る）。
  private func exists(_ relativePath: String) -> Bool {
    (try? FileManager.default.attributesOfItem(atPath: url(of: relativePath).path)) != nil
  }
}
