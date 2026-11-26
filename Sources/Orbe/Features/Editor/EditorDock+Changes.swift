import SwiftUI

/// Changes の画面の、上のバーの右下の置き場に出す札。上から、実行中の札（0.3 秒を越えて実際に走っている操作のうち、一番
/// 新しいもの）と、失敗の札（コミットのポップアップの赤い行に出していない最後の失敗）。× は最後の失敗を消す——最後の失敗は、
/// 人が起こした操作 1 回の結果で、同じ worktree で次の操作を始めたときにも消える。
extension EditorDockRoot {
  /// 今出す札を、上から出す順に並べたもの。置き場の根が描画の中で呼ぶので、観測できる持ち主の値から組む。
  @ViewBuilder var changesCards: some View {
    let control = commitPopup.panel.control
    if let operation = control.cardOperation {
      ScmRunningCard(kind: operation.kind, progress: operation.progress, stop: operation.stop)
    }
    if ScmFailurePlace(control.failure, isCommitPopupOpen: commitPopup.isOpen) == .outside,
      let failure = control.failure,
      let text = ScmFailureText.card(failure, localization.language)
    {
      EditorFailureCard(text: text, dismiss: control.clearFailure)
    }
  }
}
