import Foundation

/// 操作の始め方と 2 段の連結。どれも始めたときの根のサービスの口を呼ぶ——前提の判定・順番・止め方・失敗の分類は根のサービスが
/// 持つ。2 段の操作は 1 段目が通ったときだけ 2 段目を起こし、止められていれば起こさない（止める手の状態を段の間で見る）。
extension SourceControl {
  func stage(_ rows: [GitStatus.Row]) {
    run(.stage, .stage) { files, done in files.stage(rows, completion: done) }
  }

  func unstage(_ rows: [GitStatus.Row]) {
    run(.unstage, .unstage) { files, done in files.unstage(rows, completion: done) }
  }

  /// 確認は呼ぶ側（→ `ScmDiscardGate`）。確認した行をそのまま渡す（根のサービスが呼んだ時点の index で選び直す）。
  func discard(_ rows: [GitStatus.Row]) {
    run(.discard, .discard) { files, done in files.discard(rows, completion: done) }
  }

  /// `content` をコミットする（amend なら amend の操作）。通ればメッセージを空にする（コミットの間に打ち足していれば残す）。
  func commit(_ content: GitCommitContent = .staged) {
    let message = self.message
    let kind: Kind = content == .amend ? .amend : .commit
    let step: Step = content == .amend ? .amend : .commit
    run(kind, step) { [weak self] files, done in
      files.commit(message: message, content: content) { failure in
        if failure == nil { self?.clearMessage(ifStill: message) }
        done(failure)
      }
    }
  }

  func undoLastCommit() {
    run(.undo, .undo) { files, done in files.undoLastCommit(completion: done) }
  }

  func pull() {
    run(.pull, .pull) { [weak self] files, done, operation in self?.pull(files, operation, done) }
  }

  func push() {
    run(.push, .push) { [weak self] files, done, operation in self?.push(files, operation, done) }
  }

  func fetch() {
    run(.fetch, .fetch) { [weak self] files, done, operation in
      guard let self else { return done(.cancelled) }
      attach(
        files.fetch(
          onProgress: { [weak self] in self?.report($0, of: operation) }, completion: done),
        step: .fetch, to: operation)
    }
  }

  /// プル → プッシュ（先行・遅れの数に依らず両方走らせる）。
  func sync() {
    run(.sync, .pull) { [weak self] files, done, operation in
      self?.pull(files, operation) { failure in
        self?.continueStep(operation, after: failure, done) { self?.push(files, operation, done) }
      }
    }
  }

  /// upstream の無いブランチを upstream を付けて送る（付け方は根のサービスの push）。
  func publish() {
    run(.publish, .push) { [weak self] files, done, operation in self?.push(files, operation, done)
    }
  }

  /// `content` をコミット → プッシュ。コミットが通ればメッセージを空にしてから送る。
  func commitAndPush(_ content: GitCommitContent = .staged) {
    let message = self.message
    run(.commitAndPush, .commit) { [weak self] files, done, operation in
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
    attach(
      files.pull(onProgress: { [weak self] in self?.report($0, of: operation) }, completion: done),
      step: .pull, to: operation)
  }

  private func push(
    _ files: RootFiles, _ operation: Operation, _ done: @escaping (GitWriteFailure?) -> Void
  ) {
    attach(
      files.push(onProgress: { [weak self] in self?.report($0, of: operation) }, completion: done),
      step: .push, to: operation)
  }

  /// 1 段目が通り、止められていなければ 2 段目を起こす。そうでなければ 1 段目の結果で終える。
  private func continueStep(
    _ operation: Operation, after failure: GitWriteFailure?,
    _ done: @escaping (GitWriteFailure?) -> Void, next: () -> Void
  ) {
    guard failure == nil else { return done(failure) }
    guard !operation.isStopped else { return done(.cancelled) }
    next()
  }

  private func clearMessage(ifStill committed: String) {
    if message == committed { message = "" }
  }

  /// 1 段の書き込みの操作を始める。
  private func run(
    _ kind: Kind, _ step: Step,
    _ write: @escaping (RootFiles, @escaping (GitWriteFailure?) -> Void) -> RootFiles.Write
  ) {
    run(kind, step) { [weak self] files, done, operation in
      self?.attach(write(files, done), step: step, to: operation)
    }
  }

  /// 操作を列に載せて始める。`body` は段を結びながら（`attach`）書き込みを起こし、全段の終わりで `done` を 1 回呼ぶ。
  private func run(
    _ kind: Kind, _ step: Step,
    _ body: (RootFiles, @escaping (GitWriteFailure?) -> Void, Operation) -> Void
  ) {
    guard let operation = enqueue(kind, step) else { return }
    body(operation.files, { [weak self, operation] in self?.finish(operation, $0) }, operation)
  }
}
