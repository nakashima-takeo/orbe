import Foundation

// MARK: - 変更の書き込み（ステージ・解除・破棄・コミット・取り消し）

/// 利用者が起こす index・作業ツリー・HEAD への書き込み。どれも無出力で打ち切らず、`handle` で止める（hook・filter・
/// 署名の沈黙は「何も起きていない」ことを意味しない）。順番は呼び出し側（根のサービス）が作る——同じ worktree の
/// index へ同時に書けば、git は index.lock で待たずに落ちる。completion は main で返る。
///
/// パスはファイル名そのもの（ユーザーのデータ）なので、NUL 区切りの標準入力で渡し、その呼び出しだけ pathspec を
/// literal にする（`*` `:` を含む名前で別のファイルに当たらない。引数の長さの上限も越えない）。
extension GitRepo {
  /// 行をステージする（変更・削除・未追跡のどれでも、作業ツリーの姿を index へ）。含めるパスは呼んだ時点の index と
  /// 作業ツリーで選び直す（`selection`）。
  func stage(
    rows: [GitStatus.Row], handle: GitRunner.Handle,
    completion: @escaping (GitWriteFailure?) -> Void
  ) {
    select(rows, handle: handle) { selected in
      switch selected {
      case .failure(let failure): completion(failure)
      case .success(let selection):
        self.runOnPaths(
          ["add", "-A"], paths: selection.paths, handle: handle, completion: completion)
      }
    }
  }

  /// 行のステージを解く（index を HEAD の版へ。初回コミット前なら index から外す）。rename の行は元パスも常に含める
  /// ——index 側で rename の両側を揃えて戻すため。`restore --staged` は HEAD が無いと落ちるので `reset` を使う。
  func unstage(
    rows: [GitStatus.Row], handle: GitRunner.Handle,
    completion: @escaping (GitWriteFailure?) -> Void
  ) {
    runOnPaths(
      ["reset", "-q"], paths: rows.flatMap(\.paths), handle: handle, completion: completion)
  }

  /// 行の変更を捨てる。含めるパスは呼んだ時点の index と作業ツリーで選び直す（`selection`）。
  /// - 追跡中のパスは作業ツリーを index の版へ戻す（ステージ済みの分は残る）。
  /// - 未追跡のパスはゴミ箱へ移す（元に戻せる）。
  /// - intent-to-add（`git add -N`）のパスは index から外してからゴミ箱へ——index の版は空なので、戻すと中身を失う。
  ///
  /// 追跡中かは観測の status でなく呼んだ時点の index で決める（status が古いとき、追跡中のファイルをゴミ箱へ送らない）。
  /// ゴミ箱へは裏のスレッドで 1 件ずつ移し、その都度止められたかを見る（件数が多いと main を止めるため）。移せなければ
  /// 失敗で返し、消さない。
  func discard(
    rows: [GitStatus.Row], handle: GitRunner.Handle,
    completion: @escaping (GitWriteFailure?) -> Void
  ) {
    select(rows, handle: handle) { selected in
      switch selected {
      case .failure(let failure): completion(failure)
      case .success(let selection): self.discard(selection, handle: handle, completion: completion)
      }
    }
  }

  private func discard(
    _ selection: Selection, handle: GitRunner.Handle,
    completion: @escaping (GitWriteFailure?) -> Void
  ) {
    intentToAdd(among: selection.indexed, handle: handle) { found in
      guard case .success(let intended) = found else {
        if case .failure(let failure) = found { completion(failure) }
        return
      }
      let restore = Array(selection.indexed.subtracting(intended))
      let trash = selection.paths.filter { !restore.contains($0) }
      self.runOnPaths(["restore", "--worktree"], paths: restore, handle: handle) { restored in
        if let restored { return completion(restored) }
        let unindex = ["rm", "--cached", "-q"]
        self.runOnPaths(unindex, paths: Array(intended), handle: handle) { removed in
          if let removed { return completion(removed) }
          self.moveToTrash(trash, handle: handle, completion: completion)
        }
      }
    }
  }

  /// ステージ・破棄に含めるパスと、そのうち呼んだ時点の index に載っているもの。
  struct Selection {
    let paths: [String]
    let indexed: Set<String>
  }

  /// 行から、ステージ・破棄に含めるパスを呼んだ時点の index と作業ツリーで選び直す。
  /// - 行のパスは、index に在るか作業ツリーに在るときだけ（status を読んだ後に消えた未追跡は含めない——add の pathspec が
  ///   一致しないと、git は全体を止める）。
  /// - rename の元パスは、index に在るときだけ。作業ツリー側の rename（`.R`）では元パスは index に在り、その削除が含まれる。
  ///   ステージ済みの rename（`R.`・`RM`）では元パスは index に無く、そこへ置き直された別の未追跡ファイルを巻き込まない。
  ///
  /// index は丸ごと読む——`ls-files` はパスを標準入力で受けられず、引数では長さの上限を越えうる。読みと作業ツリーの
  /// 確かめは裏のスレッドで済ませる。
  private func select(
    _ rows: [GitStatus.Row], handle: GitRunner.Handle,
    completion: @escaping (Result<Selection, GitWriteFailure>) -> Void
  ) {
    let asked = Set(rows.flatMap(\.paths))
    runner.run(
      ["ls-files", "-z"], cwd: root, handle: handle,
      transform: { listed -> Result<Selection, GitWriteFailure> in
        if let failure = GitWriteFailure.of(listed) { return .failure(failure) }
        let indexed = Set(
          listed.stdout.split(separator: 0).compactMap { String(bytes: $0, encoding: .utf8) }
            .filter(asked.contains))
        var paths: [String] = []
        for row in rows {
          if indexed.contains(row.path) || Self.exists(self.url(of: row.path)) {
            paths.append(row.path)
          }
          if let original = row.originalPath, indexed.contains(original) { paths.append(original) }
        }
        return .success(Selection(paths: paths, indexed: indexed))
      }, completion: completion)
  }

  /// `paths` のうち intent-to-add のもの（index の版は空の blob で、作業ツリーとの差は「追加」として出る）。
  private func intentToAdd(
    among paths: Set<String>, handle: GitRunner.Handle,
    completion: @escaping (Result<Set<String>, GitWriteFailure>) -> Void
  ) {
    guard !paths.isEmpty else {
      return DispatchQueue.main.async { completion(.success([])) }
    }
    runner.run(
      ["diff-files", "-z", "--name-only", "--diff-filter=A"], cwd: root, handle: handle,
      transform: { listed -> Result<Set<String>, GitWriteFailure> in
        if let failure = GitWriteFailure.of(listed) { return .failure(failure) }
        return .success(
          Set(
            listed.stdout.split(separator: 0).compactMap { String(bytes: $0, encoding: .utf8) }
              .filter(paths.contains)))
      }, completion: completion)
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
  /// 消して初回コミット前へ戻す（index はそのまま＝全部ステージ済み）。shallow clone の境界のコミットは取り消さない。
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
      // shallow clone の境界のコミットも親を返さない。初回コミットとして ref を消すと、履歴とつながらなくなる。
      guard !self.isShallowBoundary(head) else { return completion(.shallowBoundary) }
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

  /// 裏のスレッドで 1 件ずつゴミ箱へ移し、その都度止められたかを見る。completion は main で返る。
  private func moveToTrash(
    _ paths: [String], handle: GitRunner.Handle, completion: @escaping (GitWriteFailure?) -> Void
  ) {
    let urls = paths.map(url(of:))
    DispatchQueue.global(qos: .userInitiated).async {
      var failure: GitWriteFailure?
      // 選んだ後に消えたパス（intent-to-add のまま作業ツリーから消えたもの等）は、捨てるものが無いので飛ばす。
      for url in urls where Self.exists(url) {
        guard !handle.isCancelled else {
          failure = .cancelled
          break
        }
        do {
          try Self.moveToTrash(url)
        } catch {
          failure = .reason(error.localizedDescription)
          break
        }
      }
      DispatchQueue.main.async { completion(failure) }
    }
  }

  private static func moveToTrash(_ url: URL) throws {
    guard let directory = trashDirectoryOverride else {
      try FileManager.default.trashItem(at: url, resultingItemURL: nil)
      return
    }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try FileManager.default.moveItem(
      at: url, to: directory.appendingPathComponent(url.lastPathComponent))
  }

  /// HEAD が shallow clone の境界（親が手元に無い）か。境界は共有 git dir の `shallow` に 1 行ずつ載る。
  private func isShallowBoundary(_ commit: String) -> Bool {
    let shallow = (commonDir as NSString).appendingPathComponent("shallow")
    guard let text = try? String(contentsOfFile: shallow, encoding: .utf8) else { return false }
    return text.split(separator: "\n").contains { $0 == commit }
  }

  /// パスの操作。空なら git を起こさずに成功で返す——パスの無い `add -A`・`reset`・`restore`・`rm` は全体に効く。
  private func runOnPaths(
    _ args: [String], paths: [String], handle: GitRunner.Handle,
    completion: @escaping (GitWriteFailure?) -> Void
  ) {
    guard !paths.isEmpty else { return DispatchQueue.main.async { completion(nil) } }
    let list = paths.map { $0 + "\0" }.joined()
    runner.run(
      args + ["--pathspec-from-file=-", "--pathspec-file-nul"], cwd: root, stdin: Data(list.utf8),
      environment: ["GIT_LITERAL_PATHSPECS": "1"], timesOut: false, handle: handle
    ) { completion(.of($0)) }
  }

  private func url(of relativePath: String) -> URL {
    URL(fileURLWithPath: root).appendingPathComponent(relativePath)
  }

  /// symlink を辿らずに在るか（壊れた symlink も在る）。
  private static func exists(_ url: URL) -> Bool {
    (try? FileManager.default.attributesOfItem(atPath: url.path)) != nil
  }
}
