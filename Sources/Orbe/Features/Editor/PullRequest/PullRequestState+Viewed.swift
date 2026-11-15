import Foundation

/// 確認済み——押した瞬間に書いている途中の値を重ねて見せ、GitHub への書き込みは 1 つずつ順に送る。通ったパスは GitHub の
/// 値として確定し、通らなかったパスは重ねた値を外して元に戻す。読み直しと書き込みには出した順の通し番号を付け、パスごとに
/// 最後に確定した書き込みより前に出した読み直しの答えでは、そのパスを上書きしない（書き込みより前に出して後から届いた
/// 読み直しが、通ったチェックを外さない）。書いている途中のパスも上書きしない。走っている書き込みは、見ている者が
/// いなくなっても最後まで走る。
extension PullRequestState {
  /// 変更ファイル `path` が確認済みか（書いている途中なら、その値）。
  func isViewed(_ path: String) -> Bool {
    pendingViewed[path]?.value ?? viewed[path] ?? false
  }

  /// 変更ファイルのうち確認済みの数と、変更ファイルの数。
  var viewedCount: (viewed: Int, total: Int) {
    let files = content?.files ?? []
    return (files.filter { isViewed($0.path) }.count, files.count)
  }

  /// 変更ファイル `paths` の確認済みを `value` にする。変更ファイルに無いパスは書かない。
  func setViewed(_ value: Bool, paths: [String]) {
    guard let content else { return }
    let known = Set(content.files.map(\.path))
    let targets = Set(paths.filter { known.contains($0) && isViewed($0) != value })
    guard !targets.isEmpty else { return }
    failure = nil
    let order = issueOrder()
    for path in targets { pendingViewed[path] = PendingViewed(value: value, order: order) }
    writes.append(ViewedWrite(value: value, paths: targets, nodeID: content.nodeID, order: order))
    sendNextWrite()
    notify()
  }

  private func sendNextWrite() {
    guard !isWriting, let next = writes.first else { return }
    isWriting = true
    source.setViewed(next.value, next.paths, next.nodeID) { [weak self] result in
      guard let self else { return }
      writes.removeFirst()
      isWriting = false
      for path in next.paths {
        if result.written.contains(path) {
          viewed[path] = next.value
          viewedOrder[path] = next.order
        }
        if pendingViewed[path]?.order == next.order { pendingViewed[path] = nil }
      }
      if let reason = result.failure { failure = .write(reason) }
      notify()
      sendNextWrite()
    }
  }
}
