import Foundation

// MARK: - 変更の書き込み（ステージ・解除・破棄・コミット・取り消し）

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
  /// - 追跡中のパスは作業ツリーを index の版へ戻す（ステージ済みの分は残る）。サブモジュールの中は、利用者の
  ///   `submodule.recurse` に依らず触れない（従うと中の未コミットの作業と、中で作ったコミットへの道を消す）。
  /// - 未追跡のパスはゴミ箱へ移す（元に戻せる）。
  /// - intent-to-add（`git add -N`）のパスは、作業ツリーに在れば index から外してからゴミ箱へ——index の版は空なので、
  ///   戻すと中身を失う。作業ツリーから消えたものは index の版（空）へ戻る。
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
      let restore = selection.indexed.subtracting(intended)
      let trash = selection.paths.filter { !restore.contains($0) }
      let checkout = ["restore", "--worktree", "--no-recurse-submodules"]
      self.runOnPaths(checkout, paths: Array(restore), handle: handle) { restored in
        if let restored { return completion(restored) }
        let unindex = ["rm", "--cached", "-q"]
        self.runOnPaths(unindex, paths: Array(intended), handle: handle) { removed in
          if let removed { return completion(removed) }
          self.moveToTrash(trash, handle: handle, completion: completion)
        }
      }
    }
  }

  /// ステージ・破棄に含めるパスと、そのうち呼んだ時点の index に載っているもの。`unmerged` は、その index に競合
  /// （stage が 0 でないエントリ）が残っているか。
  private struct Selection {
    let paths: [String]
    let indexed: Set<String>
    let unmerged: Bool
  }

  /// 行から、ステージ・破棄に含めるパスを呼んだ時点の index と作業ツリーで選び直す。
  /// - 行のパスは、index に在るか作業ツリーに在るときだけ（status を読んだ後に消えた未追跡は含めない——add の pathspec が
  ///   一致しないと、git は全体を止める）。
  /// - rename の元パスは、index に在るときだけ。作業ツリー側の rename（`.R`）では元パスは index に在り、その削除が含まれる。
  ///   ステージ済みの rename（`R.`・`RM`）では元パスは index に無く、そこへ置き直された別の未追跡ファイルを巻き込まない。
  ///
  /// index は丸ごと読む——`ls-files` はパスを標準入力で受けられず、引数では長さの上限を越えうる。読みと作業ツリーの
  /// 確かめは裏のスレッドで済ませる。stage の番号つきで読み、競合が残っているかも同じ読みで答える（コミットが使う）。
  private func select(
    _ rows: [GitStatus.Row], handle: GitRunner.Handle,
    completion: @escaping (Result<Selection, GitWriteFailure>) -> Void
  ) {
    let asked = Set(rows.flatMap(\.paths))
    runner.run(
      ["ls-files", "-s", "-z"], cwd: root, handle: handle,
      transform: { listed -> Result<Selection, GitWriteFailure> in
        if let failure = GitWriteFailure.of(listed) { return .failure(failure) }
        var indexed = Set<String>()
        var unmerged = false
        // `<mode> <object> <stage>\t<path>`
        for entry in listed.stdout.split(separator: 0) {
          guard let tab = entry.firstIndex(of: 0x09) else { continue }
          if tab > entry.startIndex, entry[entry.index(before: tab)] != 0x30 { unmerged = true }
          if let path = String(bytes: entry[entry.index(after: tab)...], encoding: .utf8),
            asked.contains(path)
          {
            indexed.insert(path)
          }
        }
        var paths: [String] = []
        for row in rows {
          if indexed.contains(row.path) || Self.exists(self.url(of: row.path)) {
            paths.append(row.path)
          }
          if let original = row.originalPath, indexed.contains(original) { paths.append(original) }
        }
        return .success(Selection(paths: paths, indexed: indexed, unmerged: unmerged))
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

  /// ゴミ箱の行き先の差し替え（テスト用。隔離ハーネスが毎テスト caseDir の下へ張る）。nil なら利用者のゴミ箱。
  nonisolated(unsafe) static var trashDirectoryOverride: URL?

  /// 裏のスレッドで 1 件ずつゴミ箱へ移し、その都度止められたかを見る。completion は main で返る。
  private func moveToTrash(
    _ paths: [String], handle: GitRunner.Handle, completion: @escaping (GitWriteFailure?) -> Void
  ) {
    let urls = paths.map(url(of:))
    DispatchQueue.global(qos: .userInitiated).async {
      var failure: GitWriteFailure?
      // 選んだ後に消えたパスは、捨てるものが無いので飛ばす。
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
