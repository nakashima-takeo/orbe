import Foundation

/// 最後の失敗の出し場所（純関数）。コミットの操作（コミット・amend・取り消し・コミットしてプッシュ）の失敗は、コミットの
/// ポップアップが開いていればその下の赤い行に出し、それ以外はポップアップの外に出す。失敗が無ければ出さない（nil）。
enum ScmFailurePlace: Equatable {
  /// コミットのポップアップの下の赤い行。
  case popup
  /// ポップアップの外。
  case outside

  init?(_ failure: SourceControl.Failure?, isCommitPopupOpen: Bool) {
    guard let failure else { return nil }
    switch failure.kind {
    case .commit, .amend, .undo, .commitAndPush:
      self = isCommitPopupOpen ? .popup : .outside
    case .stage, .unstage, .discard, .pull, .push, .fetch, .sync, .publish:
      self = .outside
    }
  }
}
