import Foundation

/// レビューのやりとりのうち、今の diff に置けないもの。
extension PullRequestState {
  /// 今の diff に置けない未解決のスレッド（古い版の行に付いた・ファイル単位・rename の判定が GitHub と手元で食い違う
  /// ファイルの古い側の行に付いた）の数。
  var outdatedThreadCount: Int {
    guard let head = content?.headCommit else { return 0 }
    let ends = diffEnds
    return (threads(at: head) ?? []).count { !$0.isResolved && canPlace($0, in: ends) == false }
  }
}
