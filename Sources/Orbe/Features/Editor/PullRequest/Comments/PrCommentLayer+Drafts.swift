import Foundation

/// PR のコメントの層と、PR ごとの書きかけ——書きかけを欄へ反映し（無い欄は作る）、打った本文を書き戻し、ほかの層が書いた
/// 変化を自分の欄へ合わせる。書きかけへ書くのは人が欄を打ったときだけで、書きかけを欄へ反映しても書きかけへは書き戻さない。
/// 欄の位置を書くのは書きかけを作るときだけで、行を追った結果は書かない（欄の起点から各層がその都度導く）。空白と改行だけの欄の本文
/// （開いただけの新しいコメントの欄を含む）は層だけが持ち、ほかの字が入った時点で書きかけになる。
extension PrCommentLayer {
  // MARK: - スレッド

  /// スレッド `thread` の絵の差し込みを、返信の書きかけの本文で作る（書きかけのある欄と、開くよう頼まれたスレッドは、解決済み
  /// でも開いて出す）。
  func makeZone(_ thread: GitHubPullRequestReview.Thread, line: Int) -> PrCommentZone {
    let zone = PrCommentZone(
      subject: .thread(thread), line: line, fieldID: "thread:\(thread.id)",
      text: state.commentDrafts.replies[thread.id]?.body ?? "")
    zone.isCollapsed = thread.isResolved && !zone.hasText && revealRequest?.thread != thread.id
    zone.onPress = { [weak self] zone, control in self?.press(control, in: zone) }
    zone.onTextChange = { [weak self] zone in self?.replyDidChange(zone) }
    zone.onFieldFocus = { [weak self] zone, primary in
      self?.fieldFocusDidChange(zone, primary: primary)
    }
    zone.onTypeset = { [weak self] zone in self?.zoneDidTypeset(zone) }
    threads[thread.id] = zone
    return zone
  }

  private func replyDidChange(_ zone: PrCommentZone) {
    guard case .thread(let thread) = zone.subject,
      let spot = held[thread.id]?.origin ?? lastPlaced[thread.id]
    else { return }
    state.writeReply(zone.text, to: thread, from: spot)
  }

  /// 行を追っているスレッド `id` の絵の差し込み `zone` を手放す（追っていなければ false）。削除されたスレッドは、絵の差し込みごと
  /// 手放す。
  func release(_ id: String, _ zone: PrCommentZone) -> Bool {
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
    let draft = makeDraft(state.issueCommentSerial(), at: spot, text: "")
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
    _ serial: Int, at spot: PullRequestState.CommentSpot, text: String
  ) -> PrCommentPlacement {
    let zone = PrCommentZone(
      subject: .draft(serial), line: spot.line + 1, fieldID: "draft:\(serial)", text: text)
    let draft = PrCommentPlacement(zone: zone, origin: spot)
    zone.onPress = { [weak self] zone, control in self?.press(control, in: zone) }
    zone.onTextChange = { [weak self, weak draft] zone in
      guard let self, let draft else { return }
      state.writeComment(serial, path: path, body: zone.text, from: draft.origin)
    }
    zone.onFieldFocus = { [weak self] zone, primary in
      self?.fieldFocusDidChange(zone, primary: primary)
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
      drafts.append(makeDraft(serial, at: comment.spot, text: comment.body))
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
/// 層にまだ無い書きかけがあれば、並びを置き直させて欄にする。
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
  }
}
