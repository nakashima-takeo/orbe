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

  /// 押した時点の範囲の中身——見えているステージ済みの行があればそれだけ、無ければ「すべてステージ」と同じ行を先にステージ
  /// して入れる。行が status に追いついていない間の食い違いは、根のサービスが書き込みの直前に照らして断る。
  private var commitContent: GitCommitContent {
    changes.staged.isEmpty
      ? .staging(changes.committable.map(\.row)) : .staged(changes.staged.map(\.row))
  }
}
