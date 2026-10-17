import Foundation

// MARK: - コミット・amend・最後のコミットの取り消し

/// コミットの中身（新しいコミットにも、amend にも入れる）。どちらも押した時点に見えていた行を持ち、コミットに入るパスは
/// その行のパスと一致しなければならない（→ `commit`）。
enum GitCommitContent: Equatable {
  /// ステージ済みの分。行は見えていたステージ済みの行。
  case staged([GitStatus.Row])
  /// 行を先にステージしてから。見えていたステージ済みは無い。
  case staging([GitStatus.Row])

  /// 先にステージする行。
  var stagedFirst: [GitStatus.Row] {
    if case .staging(let rows) = self { return rows }
    return []
  }

  /// 見えていたステージ済みのパス（rename は元パスも）。
  var stagedPaths: Set<String> {
    if case .staged(let rows) = self { return Set(rows.flatMap(\.paths)) }
    return []
  }
}

/// 書き込みの決まり（止め方・順番・パスの渡し方）は `GitRepo+Changes` と同じ。
extension GitRepo {
  /// コミットする（`amend` なら直前のコミットを差し替える）。中身は `content`——ステージ済みの分か、先に行をステージして
  /// から（同じ書き込みの中で `stage` と同じ規則で選び直す）。どの中身でも、呼んだ時点の index に競合が残っていれば何も
  /// 書かずに `conflictsRemain` で返す（git はコミットを断るので、先にステージしたものが merge のコミットに混ざりうるだけに
  /// なる）。コミットに入るパスが `content` の行と違えば何も書かずに `contentMismatch` で返す。amend は、呼んだ時点の HEAD
  /// が push 済みなら何も書かずに `headPushed` で返す。ステージの後で止められたらコミットしない。ステージが通ってコミットが
  /// 落ちたら、ステージしたものは残る。
  ///
  /// メッセージは書いたまま残る（`#` 始まりの行も。前後の空行・行末の空白・続く空行だけ整える）。amend でメッセージが空
  /// なら、前のメッセージを一字も変えずに中身だけ差し替える——整え方を明示しないと、利用者の `commit.cleanup=strip` が
  /// 前のメッセージの `#` の行を消す。ユーザーの hook・署名の設定はそのまま効く。
  func commit(
    message: String, content: GitCommitContent, amend: Bool, handle: GitRunner.Handle,
    completion: @escaping (GitWriteFailure?) -> Void
  ) {
    let write = {
      self.stageAndCommit(
        message: message, content: content, amend: amend, handle: handle, completion: completion)
    }
    guard amend else { return write() }
    unlessHeadIsPushed(handle: handle, completion, then: write)
  }

  private func stageAndCommit(
    message: String, content: GitCommitContent, amend: Bool, handle: GitRunner.Handle,
    completion: @escaping (GitWriteFailure?) -> Void
  ) {
    select(content.stagedFirst, handle: handle) { selected in
      switch selected {
      case .failure(let failure): completion(failure)
      case .success(let selection):
        guard !selection.unmerged else { return completion(.conflictsRemain) }
        self.unlessContentDiffers(content, staging: selection.paths, handle: handle, completion) {
          self.runOnPaths(["add", "-A"], paths: selection.paths, handle: handle) { staged in
            if let staged { return completion(staged) }
            guard !handle.isCancelled else { return completion(.cancelled) }
            self.commit(message: message, amend: amend, handle: handle, completion: completion)
          }
        }
      }
    }
  }

  /// コミットに入るパスが押した時点に見えていた行と違えば、何も書かずに `contentMismatch` で返し、同じなら `body` を続ける。
  /// git のコミットは index 全体を入れるので、今 index が HEAD と違うパスが見えていたステージ済みと、先にステージする
  /// パス（選び直した `staging`）が見えていた行と、それぞれ一致しなければならない。パネルの範囲は見えている行で決まり、
  /// 行は status より遅れて当たり、外（端末）の書き込みは監視が届くまで行に出ない——そのずれの間にも押せてしまうので、
  /// 書き込みの直前に照らす。
  private func unlessContentDiffers(
    _ content: GitCommitContent, staging: [String], handle: GitRunner.Handle,
    _ completion: @escaping (GitWriteFailure?) -> Void, then body: @escaping () -> Void
  ) {
    let staged = [
      "diff", "--cached", "--name-only", "-z", "--no-renames", "--ignore-submodules=none",
    ]
    runner.run(
      staged, cwd: root, handle: handle,
      transform: { listed -> Result<Bool, GitWriteFailure> in
        if let failure = GitWriteFailure.of(listed) { return .failure(failure) }
        let paths = Set(
          listed.stdout.split(separator: 0).compactMap { String(bytes: $0, encoding: .utf8) })
        return .success(
          paths == content.stagedPaths
            && Set(staging) == Set(content.stagedFirst.flatMap(\.paths)))
      },
      completion: { matched in
        switch matched {
        case .failure(let failure): completion(failure)
        case .success(false): completion(.contentMismatch)
        case .success(true): body()
        }
      })
  }

  private func commit(
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
  /// 消して初回コミット前へ戻す（index はそのまま＝全部ステージ済み）。呼んだ時点の HEAD が push 済みのコミットと shallow
  /// clone の境界のコミットは取り消さない。
  func undoLastCommit(handle: GitRunner.Handle, completion: @escaping (GitWriteFailure?) -> Void) {
    unlessHeadIsPushed(handle: handle, completion) {
      self.undoUnpushedLastCommit(handle: handle, completion: completion)
    }
  }

  /// HEAD が push 済み（どれかの remote 追跡ブランチから届く——グラフの push 済みと同じ定義）なら書き換えずに `headPushed`
  /// で返し、そうでなければ `body` を続ける。パネルの押せる・押せないは見せ方で、▾ を開いている間や外の push が監視に届く
  /// までの間にも押せてしまうので、書き換えの直前に読む。
  private func unlessHeadIsPushed(
    handle: GitRunner.Handle, _ completion: @escaping (GitWriteFailure?) -> Void,
    then body: @escaping () -> Void
  ) {
    let unpushed = ["rev-list", "-n", "1", "HEAD", "--not", "--remotes", "--"]
    runner.run(unpushed, cwd: root, handle: handle) { listed in
      if let failure = GitWriteFailure.of(listed) { return completion(failure) }
      guard !listed.stdoutText.isEmpty else { return completion(.headPushed) }
      body()
    }
  }

  private func undoUnpushedLastCommit(
    handle: GitRunner.Handle, completion: @escaping (GitWriteFailure?) -> Void
  ) {
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

  /// HEAD が shallow clone の境界（親が手元に無い）か。境界は共有 git dir の `shallow` に 1 行ずつ載る。
  private func isShallowBoundary(_ commit: String) -> Bool {
    let shallow = (commonDir as NSString).appendingPathComponent("shallow")
    guard let text = try? String(contentsOfFile: shallow, encoding: .utf8) else { return false }
    return text.split(separator: "\n").contains { $0 == commit }
  }
}
