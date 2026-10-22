import AppKit

/// コミットボタンの姿と、押した・開いた時点の写しで中身を決めるコミット、範囲に数える自分の書き込み。
extension ScmPanel {
  /// コミットボタンと ▾ の姿（今の行と欄で）。
  var commitState: ScmCommitState {
    ScmCommitState(
      staged: changes.staged.count, changes: changes.changes.count,
      committable: changes.committable.count, branch: branch,
      messageIsBlank: control.message.allSatisfy(\.isWhitespace),
      isNetworking: control.isNetworking, isCommitting: control.isCommitting,
      isHeadPushed: isHeadPushed)
  }

  /// 今の写し。押した（✓・ボタン・欄の ↵ / ⌘↵）・開いた（▾・…）時点に取り、可否も働きもこの写しで決める（見たものを
  /// コミットする）。開いている間も status は届いて行は外の書き込みに追いつくので、選んだ時点の行で組むと、開いている間の
  /// 外のコミットを見えていたものに数えてしまう。
  func commitSnapshot() -> ScmCommitSnapshot {
    ScmCommitSnapshot(panel: self, state: commitState, seen: ownWrites.content(changes))
  }

  /// メッセージ欄のキー——↵ はコミット、⌘↵ はコミットしてプッシュ。押した時点の写しで押せなければ音で断る（ボタンが同期・
  /// 公開でも、同期・公開は起こさない）。
  func commitFromMessage(andPush: Bool) {
    let snapshot = commitSnapshot()
    if andPush, snapshot.state.canCommitAndPush {
      snapshot.commitAndPush()
    } else if !andPush, snapshot.state.canCommit {
      snapshot.commit()
    } else {
      NSSound.beep()
    }
  }

  /// プル（HEAD を動かすので、行に出るまで見えていた HEAD に数える）。
  func pull() {
    ownWrites.record(.pull, control.pull())
  }

  /// 同期（プル → プッシュ）。
  func sync() {
    ownWrites.record(.pull, control.sync())
  }

  /// 行をステージする（行の ＋・すべてステージ）。結果が行に出るまで、コミットの範囲に数える。
  func stage(_ rows: [GitStatus.Row]) {
    ownWrites.record(.stage(rows), control.stage(rows))
  }

  /// 行のステージを解く（行の −・すべて解除）。
  func unstage(_ rows: [GitStatus.Row]) {
    ownWrites.record(.unstage(rows), control.unstage(rows))
  }

  /// 行の変更を捨てる（確認は呼ぶ側）。
  func discard(_ rows: [GitStatus.Row]) {
    ownWrites.record(.discard(rows), control.discard(rows))
  }

  /// 自分の書き込みが終わった（根のサービスの status はもう書き込み後の姿）。
  func sourceControl(
    _ control: SourceControl, firstStepDidFinish operation: SourceControl.Operation,
    failure: GitWriteFailure?
  ) {
    ownWrites.firstStepDidFinish(
      operation, failed: failure != nil, status: operation.files.status,
      seesStatus: liveFiles != nil)
  }

  /// 見えていた範囲の中身——見えている行に、このパネルで押してまだ行に出ていない書き込みを重ねたもの（→ `ScmOwnWrites`）
  /// ——でコミットの操作を始め、その書き込みも覚える。それ以外の食い違い（外の書き込み）は、根のサービスが書き込みの直前に
  /// 照らして断る。
  fileprivate func startCommit(
    _ content: GitCommitContent, _ start: (GitCommitContent) -> SourceControl.Operation?
  ) {
    ownWrites.record(.commit(stagingFirst: content.stagingFirst), start(content))
  }
}

/// 押した・開いた時点の写し——その時点のボタンの姿 `state` と、見えていたもの `seen`。働きはどれも `seen` で照らす。
@MainActor
struct ScmCommitSnapshot {
  let panel: ScmPanel
  let state: ScmCommitState
  let seen: GitCommitContent

  /// コミットする。
  func commit() {
    panel.startCommit(seen, panel.control.commit)
  }

  /// 直前のコミットを差し替える（コミットと同じ範囲）。
  func amend() {
    panel.startCommit(seen, panel.control.amend)
  }

  /// コミットしてプッシュ（コミットと同じ範囲）。
  func commitAndPush() {
    panel.startCommit(seen, panel.control.commitAndPush)
  }

  /// 最後のコミットを取り消す（見えていた HEAD のときだけ）。
  func undoLastCommit() {
    panel.ownWrites.record(.undo, panel.control.undoLastCommit(seen.head))
  }
}
