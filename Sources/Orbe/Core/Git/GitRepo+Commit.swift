import Foundation

// MARK: - コミット・amend・最後のコミットの取り消し

/// 押した時点に見えていた HEAD（パネルが渡す）。コミット・amend・取り消しは、書き込みの直前の HEAD がこれでなければ書かない。
enum GitSeenHead: Equatable {
  /// 基準のコミット（nil = 初回コミット前）から `undone` 代さかのぼったコミット（`undone` はそのパネルで押した取り消しの
  /// 数）。index は基準と比べる——取り消しは index を変えないので、取り消した後も前と同じ差のまま照らせる。
  case at(String?, undone: Int)
  /// そのパネルで押した書き込み（走っているプル・コミット）が動かす先がまだ分からない。HEAD は照らさず、index は今の HEAD
  /// と比べる。
  case movedByOwnWrite
}

/// コミットの中身（新しいコミットにも、amend にも入れる）。押した時点に見えていたもの（パネルが渡す）で、コミットはそれと
/// 違う HEAD・index に書かない（→ `commit`）。
struct GitCommitContent: Equatable {
  /// 見えていた HEAD。
  let head: GitSeenHead
  /// 見えていたステージ済み——index が HEAD（`head` の基準）と違うパス（rename は元パスも）と、その index の版。
  let staged: [String: GitStatus.IndexVersion]
  /// 版を問わないパス（そのパネルで押したステージが決める。HEAD と同じになってもよい）。`staged` とは重ならない。
  let unknown: Set<String>
  /// 先にステージする行。空なら index のままコミットする。
  let stagingFirst: [GitStatus.Row]

  /// index と基準が違うパスと、その index の版 `differing` が見えていたステージ済みと合う。
  func matches(_ differing: [String: GitStatus.IndexVersion]) -> Bool {
    staged.allSatisfy { differing[$0.key] == $0.value }
      && differing.keys.allSatisfy { staged[$0] != nil || unknown.contains($0) }
  }
}

/// 書き込みの決まり（止め方・順番・パスの渡し方）は `GitRepo+Changes` と同じ。
extension GitRepo {
  /// コミットする（`amend` なら直前のコミットを差し替える）。中身は `content`——index のままか、先に行をステージして
  /// から（同じ書き込みの中で `stage` と同じ規則で選び直す）。どの中身でも、呼んだ時点の index に競合が残っていれば何も
  /// 書かずに `conflictsRemain` で返す（git はコミットを断るので、先にステージしたものが merge のコミットに混ざりうるだけに
  /// なる）。HEAD かコミットに入るものが `content` と違えば何も書かずに `contentMismatch` で返す。amend は、呼んだ時点の HEAD
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
    select(content.stagingFirst, handle: handle) { selected in
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

  /// HEAD かコミットに入るものが押した時点に見えていたものと違えば、何も書かずに `contentMismatch` で返し、同じなら `body`
  /// を続ける。HEAD は見えていたものでなければならない（外でのコミットの上に重ねない）。
  /// git のコミットは index 全体を入れるので、今 index が基準と違うパスとその版が見えていたステージ済みと（版で比べる——
  /// 同じパスを外で別の中身にステージし直しても、名前は変わらない）、先にステージするパス（選び直した `staging`）が見えて
  /// いた行と、それぞれ一致しなければならない。パネルの範囲は見えている行で決まり、行は status より遅れて当たり、外（端末）
  /// の書き込みは監視が届くまで行に出ない——そのずれの間にも押せてしまうので、書き込みの直前に照らす。
  private func unlessContentDiffers(
    _ content: GitCommitContent, staging: [String], handle: GitRunner.Handle,
    _ completion: @escaping (GitWriteFailure?) -> Void, then body: @escaping () -> Void
  ) {
    unlessHeadMoved(content.head, handle: handle, completion) {
      self.unlessIndexDiffers(content, staging: staging, handle: handle, completion, then: body)
    }
  }

  private func unlessIndexDiffers(
    _ content: GitCommitContent, staging: [String], handle: GitRunner.Handle,
    _ completion: @escaping (GitWriteFailure?) -> Void, then body: @escaping () -> Void
  ) {
    var staged = [
      "diff", "--cached", "--raw", "--no-abbrev", "-z", "--no-renames", "--ignore-submodules=none",
    ]
    if case .at(let base?, _) = content.head { staged += [base, "--"] }
    runner.run(
      staged, cwd: root, handle: handle,
      transform: { listed -> Result<Bool, GitWriteFailure> in
        if let failure = GitWriteFailure.of(listed) { return .failure(failure) }
        return .success(
          Self.indexVersions(ofRaw: listed.stdout).map(content.matches) == true
            && Set(staging) == Set(content.stagingFirst.flatMap(\.paths)))
      },
      completion: { matched in
        switch matched {
        case .failure(let failure): completion(failure)
        case .success(false): completion(.contentMismatch)
        case .success(true): body()
        }
      })
  }

  /// rename を数えない `diff --raw -z` の出力（`:<mode> <mode> <object> <object> <status>` とパスの組）から、パスごとの
  /// 変化の後の側（index）の版。読めない組があれば nil（見えていたものと合うとは言えない）。
  private static func indexVersions(ofRaw data: Data) -> [String: GitStatus.IndexVersion]? {
    let tokens = data.split(separator: 0)
    guard tokens.count.isMultiple(of: 2) else { return nil }
    var versions: [String: GitStatus.IndexVersion] = [:]
    for meta in stride(from: 0, to: tokens.count, by: 2) {
      guard let fields = String(bytes: tokens[meta], encoding: .utf8)?.split(separator: " "),
        fields.count == 5, let path = String(bytes: tokens[meta + 1], encoding: .utf8)
      else { return nil }
      versions[path] = GitStatus.IndexVersion(mode: fields[1], object: fields[3])
    }
    return versions
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
      args, cwd: root, stdin: keepsMessage ? nil : Data(message.utf8), handle: handle
    ) { completion(.of($0)) }
  }

  /// 最後のコミットを取り消す。HEAD が 1 つ戻り、中身はステージ済みに残る。初回コミットなら、HEAD のブランチの ref を
  /// 消して初回コミット前へ戻す（index はそのまま＝全部ステージ済み）。呼んだ時点の HEAD が押した時点に見えていた `head`
  /// でなければ（外でのコミットを取り消さない）何も書かずに `contentMismatch` で返す。push 済みのコミットと shallow clone の
  /// 境界のコミットは取り消さない。
  func undoLastCommit(
    head: GitSeenHead, handle: GitRunner.Handle, completion: @escaping (GitWriteFailure?) -> Void
  ) {
    unlessHeadMoved(head, handle: handle, completion) {
      self.unlessHeadIsPushed(handle: handle, completion) {
        self.undoUnpushedLastCommit(handle: handle, completion: completion)
      }
    }
  }

  /// 今の HEAD が押した時点に見えていた `head` でなければ書かずに `contentMismatch` で返し、そうなら `body` を続ける。
  private func unlessHeadMoved(
    _ head: GitSeenHead, handle: GitRunner.Handle,
    _ completion: @escaping (GitWriteFailure?) -> Void, then body: @escaping () -> Void
  ) {
    guard case .at(let base, let undone) = head else { return body() }
    resolveCommit("HEAD", handle: handle, completion) { current in
      guard let base, undone > 0 else {
        return current == base ? body() : completion(.contentMismatch)
      }
      self.resolveCommit("\(base)~\(undone)", handle: handle, completion) { seen in
        current == seen ? body() : completion(.contentMismatch)
      }
    }
  }

  /// `name` が指すコミット（無ければ nil——初回コミット前の HEAD・根より前の祖先）。
  private func resolveCommit(
    _ name: String, handle: GitRunner.Handle,
    _ completion: @escaping (GitWriteFailure?) -> Void, then body: @escaping (String?) -> Void
  ) {
    let verify = ["rev-parse", "-q", "--verify", name + "^{commit}"]
    runner.run(verify, cwd: root, handle: handle) { parsed in
      if parsed.exited && parsed.status == 1 { return body(nil) }
      if let failure = GitWriteFailure.of(parsed) { return completion(failure) }
      body(parsed.stdoutText.trimmingCharacters(in: .newlines))
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
        self.runner.run(["reset", "--soft", "HEAD~1"], cwd: self.root, handle: handle) {
          completion(.of($0))
        }
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
        self.runner.run(["update-ref", "-d", branch, head], cwd: self.root, handle: handle) {
          completion(.of($0))
        }
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
