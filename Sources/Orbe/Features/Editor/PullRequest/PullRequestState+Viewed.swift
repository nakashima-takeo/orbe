import Foundation

/// 確認済み——押した瞬間に書いている途中の値を重ねて見せ、GitHub への書き込みは 1 つずつ順に送る。通ったパスは GitHub の
/// 値として確定し、通らなかったパスは重ねた値を外して元に戻す。読み直しには出した順の通し番号を付け、通った書き込みには、
/// GitHub が書き込みを受けたと分かった時点の番号を付ける。読み直しの答えは、そのパスに最後に確定した書き込みの番号より前に
/// 出した読み直しのものであれば、そのパスを上書きしない——書き込みを受ける前の GitHub の値を返しうるので、通ったチェックを
/// 外させない。書いている途中のパスは、読み直しの答えで GitHub の値を入れても、重ねた値を見せ続ける（書き込みが
/// 通らなければ、書いている間に届いた読み直しの値が出る）。走っている書き込みは、見ている者がいなくなっても最後まで走る。
extension PullRequestState {
  /// 変更ファイル `path` が確認済みか（書いている途中なら、その値）。
  func isViewed(_ path: String) -> Bool { viewedSnapshot.contains(path) }

  /// 今の確認済みの写し（変更ファイルの数に比例せずに取れる。後から付け外ししても変わらない）。
  var viewedSnapshot: ViewedSnapshot {
    ViewedSnapshot(viewed: viewed, pending: pendingViewed)
  }

  /// 確認済みの写し。
  struct ViewedSnapshot {
    let viewed: [String: Bool]
    let pending: [String: PendingViewed]

    /// 変更ファイル `path` が確認済みか（書いている途中なら、その値）。
    func contains(_ path: String) -> Bool { pending[path]?.value ?? viewed[path] ?? false }
  }

  /// 変更ファイルのうち確認済みの数と、変更ファイルの数。
  var viewedCount: (viewed: Int, total: Int) {
    let files = content?.files ?? []
    return (files.filter { isViewed($0.path) }.count, files.count)
  }

  /// 確認済みの書き込みの失敗を消す（失敗の知らせを閉じた）。
  func dismissViewedFailure() {
    viewedFailure = nil
  }

  /// 変更ファイル `paths` の確認済みを `value` にする。変更ファイルに無いパスは書かない。
  func setViewed(_ value: Bool, paths: [String]) {
    guard let content else { return }
    let known = Set(content.files.map(\.path))
    let targets = Set(paths.filter { known.contains($0) && isViewed($0) != value })
    guard !targets.isEmpty else { return }
    viewedFailure = nil
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
      // 通ったパスの番号は、GitHub が書き込みを受けたと分かった今の番号——これより前に出した読み直しは、書き込み前の
      // 値を返しうる。
      let accepted = issueOrder()
      for path in next.paths {
        if result.written.contains(path) {
          viewed[path] = next.value
          viewedOrder[path] = accepted
        }
        if pendingViewed[path]?.order == next.order { pendingViewed[path] = nil }
      }
      if let reason = result.failure { viewedFailure = reason }
      notify()
      sendNextWrite()
      // 時間切れは GitHub が受けていることがある。中身を読み直して、GitHub の今の値を出す（同じ値をもう一度書いても害は無い）。
      if result.failure == .timedOut { reload() }
    }
  }
}
