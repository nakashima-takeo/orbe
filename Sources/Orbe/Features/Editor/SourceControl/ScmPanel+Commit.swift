import Foundation

/// コミットボタンの姿と、押した時点の姿で中身を決めるコミット、範囲に数える自分の書き込み。
extension ScmPanel {
  /// コミットボタンと ▾ の姿。
  var commitState: ScmCommitState {
    ScmCommitState(
      staged: changes.staged.count, changes: changes.changes.count,
      committable: changes.committable.count, branch: branch,
      messageIsBlank: control.message.allSatisfy(\.isWhitespace),
      isNetworking: control.isNetworking, isCommitting: control.isCommitting,
      isHeadPushed: isHeadPushed)
  }

  /// コミットする（✓・ボタン・⌘↵）。何を入れるかは押した時点の姿で決める（見たものをコミットする）。
  func commit() {
    startCommit(ownWrites.content(changes), control.commit)
  }

  /// ▾ を開く。項目はどれも開いた時点に見えていたもので照らす——開いている間も status は届いて行は外の書き込みに追いつく
  /// ので、選んだ時点の行で組むと、開いている間の外のコミットを見えていたものに数えてしまう。
  func openCommitMenu() -> ScmCommitMenu {
    ScmCommitMenu(panel: self, seen: ownWrites.content(changes))
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

/// ▾ の項目。どれも ▾ を開いた時点に見えていたもの `seen` で照らす。
@MainActor
struct ScmCommitMenu {
  let panel: ScmPanel
  let seen: GitCommitContent

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
