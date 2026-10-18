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
    control.commit(commitContent)
  }

  /// 直前のコミットを差し替える（コミットと同じ範囲）。
  func amend() {
    control.amend(commitContent)
  }

  /// コミットしてプッシュ（コミットと同じ範囲）。
  func commitAndPush() {
    control.commitAndPush(commitContent)
  }

  /// 行をステージする（行の ＋・すべてステージ）。結果が行に出るまで、コミットの範囲に数える。
  func stage(_ rows: [GitStatus.Row]) {
    ownWrites.record(.stage, rows, control.stage(rows))
  }

  /// 行のステージを解く（行の −・すべて解除）。
  func unstage(_ rows: [GitStatus.Row]) {
    ownWrites.record(.unstage, rows, control.unstage(rows))
  }

  /// 行の変更を捨てる（確認は呼ぶ側）。
  func discard(_ rows: [GitStatus.Row]) {
    ownWrites.record(.discard, rows, control.discard(rows))
  }

  /// 押した時点の範囲の中身——見えている行に、このパネルで押してまだ行に出ていない書き込みを重ねたもの（→ `ScmOwnWrites`）。
  /// それ以外の食い違い（外の書き込み）は、根のサービスが書き込みの直前に照らして断る。
  private var commitContent: GitCommitContent {
    ownWrites.content(
      staged: changes.staged.map(\.row), committable: changes.committable.map(\.row))
  }
}
