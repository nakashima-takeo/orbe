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
      hasStaged: control.isStaging || liveFiles?.status?.hasStagedChanges == true,
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

  /// 押した時点の範囲の中身。全部なら「すべてステージ」と同じ行を先にステージする。
  private var commitContent: GitCommitContent {
    switch commitState.scope {
    case .staged: .staged
    case .all: .staging(changes.committable.map(\.row))
    }
  }
}
