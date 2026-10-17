import Foundation

/// コミットボタンの姿と、押した時点の姿で中身を決めるコミット。
extension ScmPanel {
  /// コミットボタンと ▾ の姿。
  var commitState: ScmCommitState {
    ScmCommitState(
      staged: changes.staged.count, changes: changes.changes.count,
      committable: changes.committable, branch: branch,
      messageIsBlank: control.message.allSatisfy(\.isWhitespace),
      isNetworking: control.isNetworking, isCommitting: control.isCommitting,
      isHeadPushed: isHeadPushed)
  }

  /// コミットする（✓・ボタン・⌘↵）。何を入れるかは押した時点の姿で決める（見たものをコミットする）。
  func commit() {
    control.commit(commitContent)
  }

  /// コミットしてプッシュ（コミットと同じ範囲）。
  func commitAndPush() {
    control.commitAndPush(commitContent)
  }

  /// 押した時点の範囲の中身。全部なら「変更」の競合でない行を先にステージする（「すべてステージ」と同じ集め方）。
  private var commitContent: GitCommitContent {
    switch commitState.scope {
    case .staged: .staged
    case .all: .staging(changes.changes.filter { !$0.isConflicted }.map(\.row))
    }
  }
}
