import Foundation

/// fetch の着地前に決定された PR 行（`DispatchPullRequestRoute.awaitingFetch`）の待ちと再開。決定の入口は
/// `DispatchPalette.swift` の `activate(at:)`。
extension DispatchPaletteModel {

  /// 着地前の PR 行の決定。「作成中…」のまま着地を待つ。
  func awaitRemoteFetch(_ item: DispatchItem) {
    errorMessage = nil
    isPreparing = true
    onAwaitRemoteFetch { [weak self] in self?.resumeAwaitingPullRequest(item) }
  }

  /// 着地後の再開。組み直した同じ番号の PR 行の行き先を実行する。行が消えていた・まだ着地を待つ形の
  /// ままなら、決定した PR をブラウザで開く（Enter したのに何も起きない、にはしない）。
  private func resumeAwaitingPullRequest(_ item: DispatchItem) {
    isPreparing = false
    guard case .pullRequest(let number, _)? = item.action else { return }
    let index = items.firstIndex { row in
      guard case .pullRequest(number, let route)? = row.action else { return false }
      return route != .awaitingFetch
    }
    guard let index else { return onOpenWeb(item) }
    activate(at: index)
  }
}
