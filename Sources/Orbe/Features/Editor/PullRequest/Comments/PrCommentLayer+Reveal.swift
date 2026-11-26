import Foundation
import OrbeEditorCore

/// 見せるよう頼まれたスレッド——ポップアップの未送信のコメントの行を押したとき、その行とスレッドと押したコメントを見せる頼み。
/// 頼みは、この層がそのスレッドの絵を置いて本文を組み終えた時点の見せ直しで終わり、その後に絵の高さが変わっても画面を
/// 動かさない。ほかに終わるのは、利用者が diff の面を操作した（スクロール・押下・打鍵）・次の頼みが来た・スレッドを置けないと
/// 決まった（→ `notes` の置き方）・この PR が worktree の今の open の PR でなくなった、とき。層は diff ごとなので、別の diff
/// を開けば頼みも消える。
extension PrCommentLayer {
  /// 頼み——スレッド `thread` の、コメント `comment`。`typesetting` は、見せた後に本文を組み終えるのを待っている。
  struct RevealRequest: Equatable {
    let thread: String
    let comment: String
    var typesetting = false
  }

  /// diff が見せる所——今の並びに載せたスレッドの絵とその面・付けた側と行（0 始まり。行を追う絵は、その回の置き場）・押した
  /// コメントの絵の中の縦の範囲（組んでいなければ nil）。
  struct RevealTarget {
    let zone: PrCommentZone
    let surface: any TextSurface
    let version: DiffRows.Version
    let line: Int
    let comment: Range<CGFloat>?
  }

  /// スレッド `thread` の、コメント `comment` を見せるよう頼む。絵があれば開き、まだ無ければ、絵を作るときに開いた姿で作る。
  func requestReveal(thread: String, comment: String) {
    revealRequest = RevealRequest(thread: thread, comment: comment)
    threads[thread]?.isCollapsed = false
    onRevealChange()
  }

  /// 頼まれたスレッドの絵を今の並びに載せていて、見せる時なら、その所を返し、頼みの段を進める——本文を組んでいる最中なら、
  /// 組み終えたときにもう一度だけ見せるのを待ち、そうでなければ頼みを終える（見せる前に進めるので、送った見えている範囲の
  /// 知らせの中で同じ頼みをもう一度送らない）。載せていない・面が分からない・組み終えるのを待っている間は nil。
  func takeRevealTarget() -> RevealTarget? {
    guard let request = revealRequest, !request.typesetting, isCurrentPullRequest,
      let shown = shownThreads[request.thread], let zone = shown.zone as? PrCommentZone,
      let surface = zone.surface
    else { return nil }
    if zone.isTypesetting {
      revealRequest?.typesetting = true
    } else {
      revealRequest = nil
    }
    return RevealTarget(
      zone: zone, surface: surface, version: shown.version, line: shown.line,
      comment: zone.commentSpans[request.comment])
  }

  /// `zone` の本文を組み終えた。頼まれたスレッドの、組み終えるのを待っていた絵なら、もう一度見せさせる。
  func zoneDidTypeset(_ zone: PrCommentZone) {
    guard let request = revealRequest, request.typesetting, threads[request.thread] === zone else {
      return
    }
    revealRequest?.typesetting = false
    onRevealChange()
  }

  /// 利用者が diff の面を操作した。頼みを捨てる。
  func userDidOperate() {
    endReveal()
  }

  /// 頼みを捨てる。
  func endReveal() {
    revealRequest = nil
  }

  /// diff が見せている両端 `ends` の先頭で読んだスレッド `read` で、頼まれたスレッドが消えた・置けないと決まったなら、頼みを
  /// 捨てる（まだ分からない間は残す）。
  func settleRevealRequest(
    _ read: [GitHubPullRequestReview.Thread], ends: PullRequestState.DiffEnds
  ) {
    guard let request = revealRequest else { return }
    guard let thread = read.first(where: { $0.id == request.thread }),
      state.placement(of: thread, shown: ends) != .unplaceable
    else { return endReveal() }
  }
}
