import Foundation

// MARK: - git の書き込み

/// 根のサービスが git の書き込みの入口になる。index を書くのはその worktree の根のサービスだけで、根はレジストリにより
/// worktree ごとに 1 つに決まるので、同じ worktree の index への書き込みの順番はここで作れば足りる（git は index.lock を
/// 待たずに落ちる）。index を書く操作（ステージ・解除・破棄・コミット・amend・取り消し・pull）は投げた順に 1 つずつ
/// 走り、fetch・push は並ばない。
///
/// どの書き込みも無出力で打ち切らず、止める手（`Write`）を返す。完了は「書き込みの後に始まった status の取り直し」が
/// 済んでから main で返る——完了が届いた時点で `status` はもう書き込み後の姿になっている（監視の到着を待たない）。
/// baseline の取り直しは待たない（smudge が詰まっても完了は遅れない）。git 管理外の根では呼べない（`notManaged`）。
extension RootFiles {
  /// 書き込み 1 つの止める手。順番待ちなら、その場で行列から外して「止めた」で返す（前の書き込みの終わりを待たず、
  /// git を起こさない）。走っていれば git を SIGTERM で止める。何度呼んでもよい。
  @MainActor
  final class Write {
    let handle = GitRunner.Handle()
    fileprivate var dequeue: (() -> Void)?

    func cancel() {
      handle.cancel()
      guard let dequeue else { return }
      self.dequeue = nil
      dequeue()
    }
  }

  typealias WriteBody = (
    GitRepo, GitRunner.Handle, @escaping (GitWriteFailure?) -> Void
  ) -> Void

  struct QueuedWrite {
    let write: Write
    let body: WriteBody
    let completion: (GitWriteFailure?) -> Void
  }

  /// 行をステージする（rename の元パスは、呼んだ時点の index に在るときだけ含める）。
  @discardableResult
  func stage(_ rows: [GitStatus.Row], completion: @escaping (GitWriteFailure?) -> Void) -> Write {
    enqueue({ $0.stage(rows: rows, handle: $1, completion: $2) }, completion)
  }

  /// 行のステージを解く（rename の行は元パスの削除の側も）。
  @discardableResult
  func unstage(_ rows: [GitStatus.Row], completion: @escaping (GitWriteFailure?) -> Void) -> Write {
    enqueue({ $0.unstage(rows: rows, handle: $1, completion: $2) }, completion)
  }

  /// 行の変更を捨てる。追跡中は作業ツリーを index の版へ（ステージ済みは残る）、未追跡と intent-to-add はゴミ箱へ。
  /// rename の元パスは、呼んだ時点の index に在るときだけ含める。git とゴミ箱は 1 枠で走り、後から投げた書き込みと
  /// 入れ替わらない。
  @discardableResult
  func discard(_ rows: [GitStatus.Row], completion: @escaping (GitWriteFailure?) -> Void) -> Write {
    enqueue({ $0.discard(rows: rows, handle: $1, completion: $2) }, completion)
  }

  /// ステージ済みの分をコミットする。`amend` でメッセージが空なら、前のメッセージのまま中身だけ差し替える。
  @discardableResult
  func commit(
    message: String, amend: Bool = false, completion: @escaping (GitWriteFailure?) -> Void
  ) -> Write {
    enqueue({ $0.commit(message: message, amend: amend, handle: $1, completion: $2) }, completion)
  }

  /// 最後のコミットを取り消す（中身はステージ済みに残る）。
  @discardableResult
  func undoLastCommit(completion: @escaping (GitWriteFailure?) -> Void) -> Write {
    enqueue({ $0.undoLastCommit(handle: $1, completion: $2) }, completion)
  }

  /// 取り込む。ネット待ちごと順番に入る（取り込みは index と作業ツリーを書く）。
  @discardableResult
  func pull(
    onProgress: @escaping (String) -> Void, completion: @escaping (GitWriteFailure?) -> Void
  ) -> Write {
    enqueue(
      { repo, handle, done in
        self.withFreshBranch(handle, done) {
          repo.pull(branch: $0, onProgress: onProgress, handle: handle, completion: done)
        }
      }, completion)
  }

  /// 送る。並ばない。
  @discardableResult
  func push(
    onProgress: @escaping (String) -> Void, completion: @escaping (GitWriteFailure?) -> Void
  ) -> Write {
    start(
      { repo, handle, done in
        self.withFreshBranch(handle, done) {
          repo.push(branch: $0, onProgress: onProgress, handle: handle, completion: done)
        }
      }, completion)
  }

  /// 取ってくる。並ばない。
  @discardableResult
  func fetch(
    onProgress: @escaping (String) -> Void, completion: @escaping (GitWriteFailure?) -> Void
  ) -> Write {
    start({ $0.fetch(onProgress: onProgress, handle: $1, completion: $2) }, completion)
  }

  // MARK: - 順番と完了

  private func enqueue(
    _ body: @escaping WriteBody, _ completion: @escaping (GitWriteFailure?) -> Void
  ) -> Write {
    let write = Write()
    guard repo != nil else { return reject(write, completion) }
    outstandingWrites += 1
    write.dequeue = { [self] in
      queuedWrites.removeAll { $0.write === write }
      DispatchQueue.main.async { [self] in
        completion(.cancelled)
        outstandingWrites -= 1
      }
    }
    queuedWrites.append(QueuedWrite(write: write, body: body, completion: completion))
    startNextWrite()
    return write
  }

  private func startNextWrite() {
    guard !isWriting, let repo, !queuedWrites.isEmpty else { return }
    let next = queuedWrites.removeFirst()
    next.write.dequeue = nil
    isWriting = true
    next.body(repo, next.write.handle) { [self] failure in
      isWriting = false
      startNextWrite()
      complete(failure, next.completion)
    }
  }

  private func start(
    _ body: @escaping WriteBody, _ completion: @escaping (GitWriteFailure?) -> Void
  ) -> Write {
    let write = Write()
    guard let repo else { return reject(write, completion) }
    outstandingWrites += 1
    body(repo, write.handle) { [self] failure in complete(failure, completion) }
    return write
  }

  private func reject(_ write: Write, _ completion: @escaping (GitWriteFailure?) -> Void) -> Write {
    DispatchQueue.main.async { completion(.notManaged) }
    return write
  }

  private func complete(
    _ failure: GitWriteFailure?, _ completion: @escaping (GitWriteFailure?) -> Void
  ) {
    requestStatusRefresh { [self] in
      completion(failure)
      outstandingWrites -= 1
    }
  }

  /// 前提（upstream・detached）の判定は、取り直した status のブランチで行う（打ってすぐの外の変化を読み落とさない）。
  private func withFreshBranch(
    _ handle: GitRunner.Handle, _ done: @escaping (GitWriteFailure?) -> Void,
    _ body: @escaping (GitStatus.Branch?) -> Void
  ) {
    requestStatusRefresh { [self] in
      guard !handle.isCancelled else { return done(.cancelled) }
      body(status?.branch)
    }
  }
}
