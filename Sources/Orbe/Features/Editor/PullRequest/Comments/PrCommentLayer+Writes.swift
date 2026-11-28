import Foundation

/// PR のコメントの層の押下と書き込み——送る前に確かめてから、スレッドへの返信・解決と新しいスレッドを PR ごとの状態へ頼む。
/// 返信と新しいスレッドの本文は PR ごとの書きかけから送られ、通った書きかけは状態が消す（どの層の欄も空になる・閉じる）。
/// 層が受けるのは失敗だけで、頼んだ絵の差し込みに失敗の文を出す。
extension PrCommentLayer {
  func press(_ control: PrCommentControl, in zone: PrCommentZone) {
    switch (zone.subject, control) {
    case (.thread, .collapse):
      zone.isCollapsed.toggle()
    case (.thread(let thread), .resolve):
      write(from: zone, replying: false) {
        state.writeReview(.setResolved(thread: thread.id, !thread.isResolved), completion: $0)
      }
    case (.thread(let thread), .add):
      guard zone.hasText else { return }
      write(from: zone, replying: true) {
        state.sendReply(to: thread.id, resolve: false, completion: $0)
      }
    case (.thread(let thread), .resolveReply):
      if zone.hasText {
        write(from: zone, replying: true) {
          state.sendReply(to: thread.id, resolve: true, completion: $0)
        }
      } else {
        write(from: zone, replying: false) {
          state.writeReview(.setResolved(thread: thread.id, true), completion: $0)
        }
      }
    case (.draft(let serial), .add):
      guard zone.hasText, !zone.isWriting, zone.canSend,
        let draft = drafts.first(where: { $0.zone === zone })
      else { return }
      send(serial, draft)
    case (.draft, .cancel):
      guard !zone.isWriting else { return }
      closeDraft(zone)
    default: return
    }
  }

  /// スレッドへの書き込みを `request` で頼む。同じスレッドへの書き込みが走っていれば何もしない（2 回押しても 1 回）。削除された
  /// スレッドと、行を移している最中のスレッドへは書かない。
  private func write(
    from zone: PrCommentZone, replying: Bool,
    _ request: (@escaping (GitHubReviewWriteResult) -> Void) -> Bool
  ) {
    guard case .thread(let thread) = zone.subject, zone.canSend,
      !state.isWritingReview(.thread(thread.id))
    else { return }
    if replying, !isCurrentPullRequest {
      zone.failure = L10n.string(.editorPrThreadNotCurrent, language())
      return
    }
    zone.failure = nil
    let accepted = request(failed(in: zone))
    if !accepted { zone.failure = L10n.string(.editorPrThreadNotReady, language()) }
  }

  /// 通し番号 `serial` の新しいコメントの書きかけを、欄 `draft` が導いた行に新しいスレッドとして頼む。欄が行を導いた両端が、
  /// PR の今の両端でない間（diff が古い両端を見せたままのときと、PR ごとの状態がベースの付け替えを読んでから、diff が新しい
  /// 両端の本文を読み終えるまで）は、状態が受け付けず、最新の内容を読み込んでからやり直すよう告げる。書いている間は、どの層の
  /// 欄も押せない姿になる（→ `PrCommentLayer.notes(shown:)`）。
  private func send(_ serial: Int, _ draft: PrCommentPlacement) {
    let zone = draft.zone
    guard isCurrentPullRequest else {
      zone.failure = L10n.string(.editorPrThreadNotCurrent, language())
      return
    }
    zone.failure = nil
    let accepted = state.sendComment(
      serial, range: draft.range, ends: draft.ends, completion: failed(in: zone))
    if !accepted { zone.failure = L10n.string(.editorPrThreadNotReady, language()) }
  }

  /// 書き込みの結果が失敗なら、絵の差し込み `zone` に失敗の文を出す（層か差し込みが消えていれば何もしない）。
  private func failed(in zone: PrCommentZone) -> (GitHubReviewWriteResult) -> Void {
    { [weak self, weak zone] result in
      guard let self, let zone, let failure = result.failure else { return }
      zone.failure = PrPanelText.writeFailure(failure, language())
    }
  }
}
