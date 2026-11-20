import Foundation

/// PR のコメントの層の押下と書き込み——スレッドへの返信・解決と新しいスレッドを PR ごとの状態へ頼み、結果を頼んだ絵の差し込みへ
/// 返す。
extension PrCommentLayer {
  func press(_ control: PrCommentControl, in zone: PrCommentZone) {
    let body = zone.hasText ? zone.text : ""
    switch (zone.subject, control) {
    case (.thread, .collapse):
      zone.isCollapsed.toggle()
    case (.thread(let thread), .resolve):
      write(.setResolved(thread: thread.id, !thread.isResolved), from: zone, clears: false)
    case (.thread(let thread), .add):
      guard !body.isEmpty else { return }
      write(.reply(thread: thread.id, body: body, resolve: false), from: zone, clears: true)
    case (.thread(let thread), .resolveReply):
      if body.isEmpty {
        write(.setResolved(thread: thread.id, true), from: zone, clears: false)
      } else {
        write(.reply(thread: thread.id, body: body, resolve: true), from: zone, clears: true)
      }
    case (.draft, .add):
      guard !body.isEmpty, !zone.isWriting, zone.canSend,
        let draft = drafts.first(where: { $0.zone === zone })
      else { return }
      writeDraft(draft, body: body)
    case (.draft, .cancel):
      guard !zone.isWriting else { return }
      closeDraft(zone)
    default: return
    }
  }

  /// スレッドへの書き込みを頼む。同じスレッドへの書き込みが走っていれば何もしない（2 回押しても 1 回）。削除されたスレッドと、
  /// 行を移している最中のスレッドへは書かない。返信が通れば、解決が通らなくても欄を空にする（返信は保留中のレビューに積まれて
  /// いるので、送り直すと同じ返信が 2 つ積まれる）。
  private func write(_ write: GitHubReviewWrite, from zone: PrCommentZone, clears: Bool) {
    guard case .thread(let thread) = zone.subject, zone.canSend,
      !state.isWritingReview(.thread(thread.id))
    else { return }
    if case .reply = write, !isCurrentPullRequest {
      zone.failure = L10n.string(.editorPrThreadNotCurrent, language())
      return
    }
    zone.failure = nil
    let accepted = state.writeReview(write) { [weak self, weak zone] result in
      guard let self, let zone else { return }
      if let failure = result.failure {
        zone.failure = PrPanelText.writeFailure(failure, language())
      }
      if clears, result.failure == nil || result.replied { zone.clearField() }
    }
    if !accepted { zone.failure = L10n.string(.editorPrThreadNotReady, language()) }
  }

  /// 新しいスレッドを頼む。書いている間は欄を押せない姿にし、通れば欄を閉じる（スレッドは読み直しで出る）。結果は頼んだ呼び出しの
  /// 中に届くこともあるので、書いている姿は頼む前に付ける。
  private func writeDraft(_ draft: PrCommentPlacement, body: String) {
    let zone = draft.zone
    // 欄が行を数えた両端が PR の今の両端でない間（ベースの付け替えを読んで、diff が新しい両端の本文を読み終える前）は書かない。
    guard state.diffEnds == draft.ends else {
      zone.failure = L10n.string(.editorPrThreadNotReady, language())
      return
    }
    guard isCurrentPullRequest else {
      zone.failure = L10n.string(.editorPrThreadNotCurrent, language())
      return
    }
    zone.failure = nil
    zone.isWriting = true
    let write = GitHubReviewWrite.addThread(
      path: path, side: draft.version == .old ? .old : .new, line: draft.line + 1,
      commit: draft.ends.head, body: body)
    let accepted = state.writeReview(write) { [weak self, weak zone] result in
      guard let self, let zone else { return }
      zone.isWriting = false
      if let failure = result.failure {
        zone.failure = PrPanelText.writeFailure(failure, language())
        return
      }
      zone.clearField()
      closeDraft(zone)
    }
    if !accepted {
      zone.isWriting = false
      zone.failure = L10n.string(.editorPrThreadNotReady, language())
    }
  }
}
