import Foundation

/// 操作の始め方と 2 段の連結。どれも始めたときの根のサービスの口を呼ぶ——前提の判定・順番・止め方・失敗の分類は根のサービスが
/// 持つ。2 段の操作は 1 段目が通ったときだけ 2 段目を起こし、止められていれば起こさない（止める手の状態を段の間で見る）。
extension SourceControl {
  @discardableResult
  func stage(_ rows: [GitStatus.Row]) -> Operation? {
    run(.stage, .stage) { files, done in files.stage(rows, completion: done) }
  }

  @discardableResult
  func unstage(_ rows: [GitStatus.Row]) -> Operation? {
    run(.unstage, .unstage) { files, done in files.unstage(rows, completion: done) }
  }

  /// 確認は呼ぶ側（→ `ScmDiscardGate`）。確認した行をそのまま渡す（根のサービスが呼んだ時点の index で選び直す）。
  @discardableResult
  func discard(_ rows: [GitStatus.Row]) -> Operation? {
    run(.discard, .discard) { files, done in files.discard(rows, completion: done) }
  }

  /// `content` をコミットする。通ればメッセージを空にする（コミットの間に打ち足していれば残す）。
  @discardableResult
  func commit(_ content: GitCommitContent) -> Operation? {
    commit(content, amend: false)
  }

  /// `content` で直前のコミットを差し替える（メッセージが空なら前のメッセージのまま）。
  @discardableResult
  func amend(_ content: GitCommitContent) -> Operation? {
    commit(content, amend: true)
  }

  private func commit(_ content: GitCommitContent, amend: Bool) -> Operation? {
    let message = self.message
    return run(amend ? .amend : .commit, amend ? .amend : .commit) { [weak self] files, done in
      files.commit(message: message, content: content, amend: amend) { failure in
        if failure == nil { self?.clearMessage(ifStill: message) }
        done(failure)
      }
    }
  }

  /// HEAD が `head` のときだけ取り消す。
  @discardableResult
  func undoLastCommit(_ head: GitSeenHead) -> Operation? {
    run(.undo, .undo) { files, done in files.undoLastCommit(head: head, completion: done) }
  }

  @discardableResult
  func pull() -> Operation? {
    run(.pull, .network(.pull)) { [weak self] files, done, operation in
      self?.pull(files, operation, done)
    }
  }

  func push() {
    run(.push, .network(.push)) { [weak self] files, done, operation in
      self?.push(files, operation, done)
    }
  }

  func fetch() {
    run(.fetch, .network(.fetch)) { [weak self] files, done, operation in
      self?.network(.fetch, of: operation, done) { finished in
        files.fetch(
          onProgress: { [weak self] in self?.report($0, of: operation) }, completion: finished)
      }
    }
  }

  /// プル → プッシュ（先行・遅れの数に依らず両方走らせる）。
  @discardableResult
  func sync() -> Operation? {
    run(.sync, .network(.pull)) { [weak self] files, done, operation in
      self?.pull(files, operation) { failure in
        self?.continueStep(operation, after: failure, done) { self?.push(files, operation, done) }
      }
    }
  }

  /// upstream の無いブランチを upstream を付けて送る（付け方は根のサービスの push）。
  func publish() {
    run(.publish, .network(.push)) { [weak self] files, done, operation in
      self?.push(files, operation, done)
    }
  }

  /// `content` をコミット → プッシュ。コミットが通ればメッセージを空にしてから送る。
  @discardableResult
  func commitAndPush(_ content: GitCommitContent) -> Operation? {
    let message = self.message
    return run(.commitAndPush, .commit) { [weak self] files, done, operation in
      guard let self else { return done(.cancelled) }
      attach(
        files.commit(message: message, content: content) { [weak self] failure in
          if failure == nil { self?.clearMessage(ifStill: message) }
          self?.continueStep(operation, after: failure, done) {
            self?.push(files, operation, done)
          }
        }, step: .commit, to: operation)
    }
  }

  // MARK: - 段

  private func pull(
    _ files: RootFiles, _ operation: Operation, _ done: @escaping (GitWriteFailure?) -> Void
  ) {
    network(.pull, of: operation, done) { finished in
      files.pull(
        onProgress: { [weak self] in self?.report($0, of: operation) }, completion: finished)
    }
  }

  private func push(
    _ files: RootFiles, _ operation: Operation, _ done: @escaping (GitWriteFailure?) -> Void
  ) {
    network(.push, of: operation, done) { finished in
      files.push(
        onProgress: { [weak self] in self?.report($0, of: operation) }, completion: finished)
    }
  }

  /// ネットの段（`write` が、渡した完了で起こす書き込み）を起こして結ぶ。そのリポジトリの裏の fetch が走っていれば、止めて
  /// その終わりを待ってから起こす——待つ間も操作は走っている扱いで帯に出し、止められたら待ちを取り下げてその場で「止めた」で
  /// 終える。譲るのはネットの段の直前だけ（コミットしてプッシュのコミットは押した時点で順番に入り、待つ間に押した操作が先に
  /// 走らない）。起こした段の終わりは、裏の fetch の係へも届ける（取り下げた段は起こしていないので届けない）。
  private func network(
    _ step: NetworkStep, of operation: Operation, _ done: @escaping (GitWriteFailure?) -> Void,
    _ write: @escaping (@escaping (GitWriteFailure?) -> Void) -> RootFiles.Write
  ) {
    let autoFetch = operation.autoFetch
    let start: () -> Void = { [weak self] in
      self?.attach(
        write { failure in
          autoFetch?.networkStepDidFinish(step, failure)
          done(failure)
        }, step: .network(step), to: operation)
    }
    guard let autoFetch,
      let withdraw = autoFetch.yield(then: { [weak self] in
        self?.endYielding(operation)
        start()
      })
    else { return start() }
    beginYielding(operation, before: .network(step)) {
      withdraw()
      done(.cancelled)
    }
  }

  /// 1 段目が通り、止められていなければ 2 段目を起こす。そうでなければ 1 段目の結果で終える。
  private func continueStep(
    _ operation: Operation, after failure: GitWriteFailure?,
    _ done: @escaping (GitWriteFailure?) -> Void, next: () -> Void
  ) {
    finishFirstStep(operation, failure)
    guard failure == nil else { return done(failure) }
    guard !operation.isStopped else { return done(.cancelled) }
    next()
  }

  private func clearMessage(ifStill committed: String) {
    if message == committed { message = "" }
  }

  /// 1 段の書き込みの操作を始める（列に載せなければ nil）。
  @discardableResult
  private func run(
    _ kind: Kind, _ step: Step,
    _ write: @escaping (RootFiles, @escaping (GitWriteFailure?) -> Void) -> RootFiles.Write
  ) -> Operation? {
    run(kind, step) { [weak self] files, done, operation in
      self?.attach(write(files, done), step: step, to: operation)
    }
  }

  /// 操作を列に載せて始める。`body` は段を結びながら（`attach`・ネットの段は `network`）書き込みを起こし、全段の終わりで
  /// `done` を 1 回呼ぶ。ネット操作は、始まりでそのリポジトリの裏の fetch の係に届け出る（届け出ている間は裏の fetch を撃た
  /// ない）。根の git dir がまだ分からなければ届け出ない（書き込みは git を起こさずに「管理外」で返るので、裏の fetch と
  /// 競らない）。
  @discardableResult
  private func run(
    _ kind: Kind, _ step: Step,
    _ body: @escaping (RootFiles, @escaping (GitWriteFailure?) -> Void, Operation) -> Void
  ) -> Operation? {
    guard let operation = enqueue(kind, step) else { return nil }
    let done: (GitWriteFailure?) -> Void = { [weak self, operation] failure in
      self?.finish(operation, failure)
    }
    if kind.isNetwork, let repo = operation.files.repo {
      let autoFetch = ScmAutoFetch.shared(for: repo)
      autoFetch.humanWillStart()
      operation.autoFetch = autoFetch
    }
    body(operation.files, done, operation)
    return operation
  }
}
