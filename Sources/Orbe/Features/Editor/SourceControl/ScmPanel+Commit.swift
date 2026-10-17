import Foundation

/// コミットボタンの姿と、押した時点の姿で中身を決めるコミット。
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

  /// 押した時点の範囲の中身。見えている行・根のサービスの今の status・列にあるステージのどれかがステージ済みを示せば
  /// ステージ済みだけ。どれも示さなければ「すべてステージ」と同じ行を先にステージして入れる——行の組み直しは status より
  /// 遅れて当たるので、ずれている間はステージ済みの側に倒す（見えていない変更は入らない）。
  private var commitContent: GitCommitContent {
    let hasStaged =
      !changes.staged.isEmpty || control.isStaging
      || liveFiles?.status?.hasStagedChanges == true
    return hasStaged ? .staged : .staging(changes.committable.map(\.row))
  }
}
