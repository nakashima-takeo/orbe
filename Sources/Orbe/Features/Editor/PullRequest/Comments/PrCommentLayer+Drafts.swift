import Foundation

/// PR のコメントの層と、PR ごとの書きかけ——書きかけを欄へ反映し（無い欄は作る）、打った本文と欄の位置を書き戻し、ほかの層が
/// 書いた変化を自分の欄へ合わせる。書きかけへ書くのは、人が欄を打ったときと行を追った結果だけで、書きかけを欄へ反映しても
/// 書きかけへは書き戻さない（打っていない側の層が、スレッドの値と欄の位置を自分の値で上書きしない）。空白と改行だけの欄の本文
/// （開いただけの新しいコメントの欄を含む）は層だけが持ち、ほかの字が入った時点で書きかけになる。
extension PrCommentLayer {
  // MARK: - スレッド

  /// スレッド `thread` の絵の差し込みを、返信の書きかけの本文で作る（書きかけのある欄は、解決済みでも開いて出す）。
  func makeZone(_ thread: GitHubPullRequestReview.Thread, line: Int) -> PrCommentZone {
    let zone = PrCommentZone(
      subject: .thread(thread), line: line, fieldID: "thread:\(thread.id)",
      text: state.commentDrafts.replies[thread.id]?.body ?? "")
    zone.isCollapsed = thread.isResolved && !zone.hasText
    zone.onPress = { [weak self] zone, control in self?.press(control, in: zone) }
    zone.onTextChange = { [weak self] zone in self?.replyDidChange(zone) }
    zone.onHasTextChange = { [weak self] _ in self?.onDraftChange() }
    zone.onFieldFocus = { [weak self] zone, primary in
      // 置けなくなった・削除されたスレッドは、書きかけを空にして焦点が外れたら手放す。
      guard let self, !primary, !zone.hasText, case .thread(let thread) = zone.subject,
        release(thread.id, zone)
      else { return }
      onRowsChange()
    }
    threads[thread.id] = zone
    return zone
  }

  private func replyDidChange(_ zone: PrCommentZone) {
    guard case .thread(let thread) = zone.subject,
      let spot = held[thread.id]?.spot ?? lastPlaced[thread.id]
    else { return }
    state.setReply(zone.text, to: thread, at: spot)
  }

  /// 行を追っているスレッド `id` の絵の差し込み `zone` を手放す（追っていなければ false）。削除されたスレッドは、絵の差し込みごと
  /// 手放す。
  private func release(_ id: String, _ zone: PrCommentZone) -> Bool {
    guard held.removeValue(forKey: id) != nil else { return false }
    if zone.notice == .deleted {
      threads[id] = nil
      lastPlaced[id] = nil
    }
    zone.notice = nil
    zone.isLineMoving = false
    return true
  }

  // MARK: - 新しいコメントの欄

  /// 側 `version` の行 `line`（0 始まり）の下に新しいコメントの欄を開き、焦点を入れる（その行に送れる欄が開いていれば焦点
  /// だけ入れる）。
  func openDraft(_ version: DiffRows.Version, line: Int) {
    guard let placed else { return }
    if let draft = drafts.first(where: {
      $0.version == version && $0.line == line && !$0.isGone
    }) {
      draft.zone.surface?.focus(draft.zone.field)
      return
    }
    let spot = PullRequestState.CommentSpot(
      side: version == .old ? .old : .new, line: line, ends: placed.ends, basis: placed.shown)
    let draft = makeDraft(state.issueCommentSerial(), at: spot, isGone: false, text: "")
    drafts.append(draft)
    onRowsChange()
    draft.zone.surface?.focus(draft.zone.field)
  }

  /// 新しいコメントの欄を閉じ、その書きかけを消す（「取り消す」・空の欄から焦点が外れた）。
  func closeDraft(_ zone: PrCommentZone) {
    guard let index = drafts.firstIndex(where: { $0.zone === zone }) else { return }
    drafts.remove(at: index)
    if let serial = zone.draftSerial { state.removeComment(serial) }
    onRowsChange()
  }

  /// 通し番号 `serial` の新しいコメントの欄を、位置 `spot` に本文 `text` で作る。
  private func makeDraft(
    _ serial: Int, at spot: PullRequestState.CommentSpot, isGone: Bool, text: String
  ) -> PrCommentPlacement {
    let zone = PrCommentZone(
      subject: .draft(serial), line: spot.line + 1, fieldID: "draft:\(serial)", text: text)
    let draft = PrCommentPlacement(zone: zone, spot: spot, isGone: isGone)
    zone.onPress = { [weak self] zone, control in self?.press(control, in: zone) }
    zone.onTextChange = { [weak self, weak draft] zone in
      guard let self, let draft else { return }
      state.setComment(
        serial, path: path, body: zone.text, at: draft.spot, isGone: draft.isGone)
    }
    zone.onHasTextChange = { [weak self] _ in self?.onDraftChange() }
    zone.onFieldFocus = { [weak self] zone, primary in
      guard let self, !primary, !zone.hasText, !zone.isWriting else { return }
      closeDraft(zone)
    }
    draft.onMove = { [weak self] draft in
      self?.state.moveComment(serial, to: draft.spot, isGone: draft.isGone)
    }
    return draft
  }

  // MARK: - 書きかけの反映

  /// このファイルの書きかけのうち、層にまだ無いものを欄にする——返信は絵の差し込みを作り
  /// （置けるかは並びが決め、置けなければ書きかけの欄の位置から行を追う）、新しいコメントは書きかけの欄の位置に欄を開く。
  func adoptDrafts() {
    let stored = state.commentDrafts
    for reply in stored.replies.values where adopts(reply) {
      _ = makeZone(reply.thread, line: reply.spot.line + 1)
    }
    let comments = stored.comments.filter { adopts($0.key, $0.value) }
    guard !comments.isEmpty else { return }
    for (serial, comment) in comments {
      drafts.append(makeDraft(serial, at: comment.spot, isGone: comment.isGone, text: comment.body))
    }
    drafts.sort { ($0.zone.draftSerial ?? 0) < ($1.zone.draftSerial ?? 0) }
  }

  private func adopts(_ reply: PullRequestState.ReplyDraft) -> Bool {
    reply.thread.path == path && threads[reply.thread.id] == nil
  }

  private func adopts(_ serial: Int, _ comment: PullRequestState.CommentDraft) -> Bool {
    comment.path == path && !drafts.contains { $0.zone.draftSerial == serial }
  }
}

/// ほかの層（か状態）が書いた変化を自分の欄へ合わせる。
/// 返信の欄は、本文を置く。空白と改行のほかの字がある欄の書きかけが消えたら、その欄を空にする。行を追っている欄は、焦点が無ければ手放す。
/// 新しいコメントの欄は、本文を置く。空白と改行のほかの字がある欄の書きかけが消えていれば、閉じる（送った・取り消した・ほかの場所で空にした）。
/// 層にまだ無い書きかけがあれば、並びを置き直させて欄にし、層が書きかけを持ったと `onDraftChange` で知らせる（仮のタブを普通の
/// タブにする）。
extension PrCommentLayer: PullRequestCommentDraftsObserver {
  func pullRequestCommentDraftsDidChange(_ state: PullRequestState) {
    let stored = state.commentDrafts
    var changed = false
    for (id, zone) in threads {
      if let reply = stored.replies[id] {
        zone.setText(reply.body)
        continue
      }
      if zone.hasText { zone.setText("") }
      if !zone.isFieldPrimary, release(id, zone) { changed = true }
    }
    for draft in drafts {
      guard let serial = draft.zone.draftSerial else { continue }
      if let comment = stored.comments[serial] {
        draft.zone.setText(comment.body)
      } else if draft.zone.hasText {
        drafts.removeAll { $0 === draft }
        changed = true
      }
    }
    let adopting =
      stored.replies.values.contains { adopts($0) }
      || stored.comments.contains { adopts($0.key, $0.value) }
    if changed || adopting { onRowsChange() }
    if adopting { onDraftChange() }
  }
}
