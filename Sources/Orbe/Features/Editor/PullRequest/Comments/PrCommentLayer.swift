import Foundation
import OrbeEditorCore

/// PR の diff のコメントの層——PR ごとの状態のスレッドを diff の行の下に置き、行の右端の印から新しいコメントの欄を開き、
/// 返信・解決・新しいスレッドの書き込みを PR ごとの状態へ頼む。PR の diff タブ 1 つに 1 つ。
///
/// 層が持つのはタブごとの見せ方——スレッドの id → 絵の差し込み、開いている新しいコメントの欄と、返信の書きかけを持ったまま
/// 今の diff に置けなくなったスレッドの置き場所（`PrCommentPlacement`）、畳んでいるか。絵の差し込みはスレッドの id で
/// 使い回すので、返信の書きかけは読み直し・並びの置き直し・インライン ⇄ 並列をまたいで残る。スレッドを置くのは、diff が
/// 見せている両端の先頭のコミットで読んだスレッドだけ（古い版の行に付けない）。書き込みの結果は頼んだ層へ返り、通れば欄を
/// 空にし（新しいコメントの欄は閉じ）、通らなければ本文を残して失敗の文を出す——同じ PR の別のタブの書きかけは変わらない。
@MainActor
final class PrCommentLayer {
  let pullRequest: EditorDiffPullRequest
  /// 並びを置き直させる（スレッドの出入り・新しいコメントの欄の開閉・印を出せる行が分かった）。
  var onRowsChange: () -> Void = {}
  private let language: () -> Language
  private var threads: [String: PrCommentZone] = [:]
  /// スレッドを最後に置いた所——側・行（0 始まり）と、そのときの両端と両側の本文（今の diff に置けなくなったときに、行を
  /// 追い始める所）。
  private var lastPlaced: [String: Seen] = [:]
  /// 返信の書きかけを持ったまま今の diff に置けなくなったスレッドの置き場所。
  private var held: [String: PrCommentPlacement] = [:]
  /// 開いた順の新しいコメントの欄。
  private var drafts: [PrCommentPlacement] = []
  /// 新しいコメントの欄の入力欄の通し番号。
  private var draftSerial = 0
  /// 求めた（求めている）印を出せる行の、両端と結果。
  private var commentable: (ends: PullRequestState.DiffEnds, lines: GitDiffHunkLines?)?
  /// 最後に並びへ注記を渡した両端とその両側の本文、並列の古い側の面（インラインでは nil）。
  private var placed: Placed?
  private weak var oldSurface: (any TextSurface)?

  /// diff の両端と両側の本文。
  private struct Placed {
    let ends: PullRequestState.DiffEnds
    let shown: EditorDiff.SideTexts
  }

  /// スレッドを置いた所。
  private struct Seen {
    let side: DiffRows.Version
    let line: Int
    let placed: Placed
  }

  init(pullRequest: EditorDiffPullRequest, language: @escaping () -> Language) {
    self.pullRequest = pullRequest
    self.language = language
  }

  var state: PullRequestState { pullRequest.state }
  var path: String { pullRequest.id.path }

  /// 裏の仕事（本文の組版・印を出せる行・欄の行の移し）が残っていない。
  var isSettled: Bool {
    !threads.values.contains(where: \.isTypesetting) && drafts.allSatisfy(\.isSettled)
      && held.values.allSatisfy(\.isSettled) && (placed == nil || commentable?.lines != nil)
  }

  /// スレッド `id` の絵の差し込み（まだ置いていなければ nil）。
  func zone(thread id: String) -> PrCommentZone? { threads[id] }

  /// 側 `version` の行 `line`（0 始まり）に置いている新しいコメントの欄（行が現在の diff に無い欄を含む）。
  func draft(_ version: DiffRows.Version, line: Int) -> PrCommentZone? {
    drafts.first { $0.version == version && $0.line == line }?.zone
  }

  // MARK: - 並び

  /// diff が見せている両側の本文 `shown` の並びに混ぜる注記。スレッドの値と書き込みの最中かを絵の差し込みへ写し、見せている
  /// 両端の先頭のコミットで読んだスレッドのうち今の diff に置けるもの（`PullRequestState.canPlace`）と、行を追う欄（新しい
  /// コメントの欄と、返信の書きかけを持ったまま置けなくなったスレッド）を置く。別の両端で行を数えた欄は、行を今の版へ移し
  /// 始める。両端が分からなければ何も置かない。
  func notes(shown: EditorDiff.SideTexts?) -> DiffRows.Notes {
    guard let shown, let ends = pullRequest.ends(of: shown) else {
      placed = nil
      return DiffRows.Notes()
    }
    let current = Placed(ends: ends, shown: shown)
    placed = current
    let language = language()
    var notes = DiffRows.Notes()
    notes.commentable = commentableLines(ends)
    // diff が見せている両端が PR の今の両端でない間（PR への push・ベースの付け替えを読んで、両端を求め直し、diff が
    // 新しい両端の本文を読み終えるまで）は、古い側の行のスレッドを前の並びに置かない（GitHub は古い側の行を今の
    // マージベースの diff の行として読む）。
    let isCurrent = state.diffEnds == ends
    if let read = state.threads(at: ends.head) {
      let ids = Set(read.map(\.id))
      for (id, zone) in threads where !ids.contains(id) { forget(id, zone) }
      // 同じ行（並びの同じ所）の差し込みは列の順に上から並ぶので、側を問わず最初のコメントの時刻の順に積み、行を追う欄は
      // その後に積む。
      let ordered = read.filter { $0.path == path }.sorted { a, b in
        (a.comments.first?.createdAt ?? .distantPast, a.id)
          < (b.comments.first?.createdAt ?? .distantPast, b.id)
      }
      for thread in ordered {
        guard state.canPlace(thread, in: ends) == true, isCurrent || thread.side == .new,
          let line = thread.line
        else {
          hold(thread)
          continue
        }
        let zone = zone(for: thread, line: line)
        held[thread.id] = nil
        zone.notice = nil
        zone.isLineMoving = false
        zone.language = language
        zone.isWriting = state.isWritingReview(.thread(thread.id))
        let side = Self.version(thread.side)
        lastPlaced[thread.id] = Seen(side: side, line: line - 1, placed: current)
        notes.zones.append(DiffRows.Zone(version: side, line: line - 1, zone: zone))
        switch side {
        case .old: notes.threads.old.insert(line - 1)
        case .new: notes.threads.new.insert(line - 1)
        }
      }
    }
    let following =
      held.sorted { a, b in
        let (x, y) = (a.value.zone.firstCommentTime, b.value.zone.firstCommentTime)
        return (x, a.key) < (y, b.key)
      }.map(\.value) + drafts
    for placement in following {
      placement.follow(
        ends, shown: shown, commentable: commentable?.lines != nil ? notes.commentable : nil,
        limit: EditorDiff.hunkLimit
      ) { [weak self] in self?.onRowsChange() }
      if case .draft = placement.zone.subject {
        placement.zone.notice = placement.isGone ? .lineGone : nil
      }
      placement.zone.language = language
      notes.zones.append(
        DiffRows.Zone(version: placement.version, line: placement.line, zone: placement.zone))
    }
    return notes
  }

  /// 今の diff に置けないスレッド `thread` に返信の書きかけがあれば、最後に置いた所から行を追う（返信と解決は送れる）。
  /// 書きかけが無ければ置かない。
  private func hold(_ thread: GitHubPullRequestReview.Thread) {
    guard let zone = threads[thread.id], startHolding(thread.id, zone) else { return }
    zone.notice = .detached
    zone.update(.thread(thread))
    zone.isWriting = state.isWritingReview(.thread(thread.id))
  }

  /// レビューのやりとりから消えたスレッド `id` を手放す。返信の書きかけがあれば、最後に置いた所から行を追って残し、削除
  /// された旨を出して送れない姿にする（書きかけを空にして焦点が外れたら手放す）。
  private func forget(_ id: String, _ zone: PrCommentZone) {
    guard startHolding(id, zone) else {
      threads[id] = nil
      lastPlaced[id] = nil
      held[id] = nil
      return
    }
    zone.notice = .deleted
  }

  /// スレッド `id` の絵の差し込み `zone` を、最後に置いた所から追い始める（追っていればそのまま）。返信の書きかけが無ければ
  /// 追わずに false。
  private func startHolding(_ id: String, _ zone: PrCommentZone) -> Bool {
    if held[id] != nil { return true }
    guard zone.hasText, let seen = lastPlaced[id] else { return false }
    zone.isCollapsed = false
    held[id] = PrCommentPlacement(
      zone: zone, version: seen.side, line: seen.line, ends: seen.placed.ends,
      basis: seen.placed.shown)
    return true
  }

  /// 並びを置いた面を絵の差し込みへ写す（`old` は並列の古い側の面。インラインなら nil で、どの差し込みも `new` に置く）。
  func place(old: (any TextSurface)?, new: any TextSurface) {
    oldSurface = old
    for zone in threads.values {
      guard case .thread(let thread) = zone.subject else { continue }
      zone.surface = thread.side == .old ? old ?? new : new
    }
    for placement in Array(held.values) + drafts {
      placement.zone.surface = placement.version == .old ? old ?? new : new
    }
  }

  private static func version(_ side: GitHubDiffSide) -> DiffRows.Version {
    side == .old ? .old : .new
  }

  /// スレッド `thread` の絵の差し込み（無ければ作る。初めて見るスレッドは、解決済みなら畳む）。
  private func zone(for thread: GitHubPullRequestReview.Thread, line: Int)
    -> PrCommentZone
  {
    if let zone = threads[thread.id] {
      zone.line = line
      zone.update(.thread(thread))
      return zone
    }
    let zone = PrCommentZone(
      subject: .thread(thread), line: line, fieldID: "thread:\(thread.id)")
    zone.isCollapsed = thread.isResolved
    zone.onPress = { [weak self] zone, control in self?.press(control, in: zone) }
    zone.onFieldFocus = { [weak self] zone, primary in
      // 置けなくなった・削除されたスレッドは、書きかけを空にして焦点が外れたら手放す。
      guard let self, !primary, !zone.hasText, case .thread(let thread) = zone.subject,
        held.removeValue(forKey: thread.id) != nil
      else { return }
      if zone.notice == .deleted {
        threads[thread.id] = nil
        lastPlaced[thread.id] = nil
      }
      zone.notice = nil
      zone.isLineMoving = false
      onRowsChange()
    }
    threads[thread.id] = zone
    return zone
  }

  /// 両端 `ends` の、印を出せる行（0 始まりの半開区間）。まだ求めていなければ裏で求め始め、求め終えたら並びを置き直させる。
  /// rename の判定が GitHub と手元で食い違うファイルでは、古い側の行に印を出さない（古い側の行の対応が変わる）。
  private func commentableLines(_ ends: PullRequestState.DiffEnds)
    -> (old: [Range<Int>], new: [Range<Int>])
  {
    if commentable?.ends != ends {
      commentable = (ends, nil)
      let path = path
      state.repo?.hunkLines(
        from: ends.mergeBase, to: ends.head, path: path, originalPath: ends.renames[path]
      ) { [weak self] lines in
        guard let self, commentable?.ends == ends else { return }
        commentable = (ends, lines ?? GitDiffHunkLines(old: [], new: []))
        onRowsChange()
      }
    }
    guard let lines = commentable?.lines else { return ([], []) }
    let ranges = { (lines: [ClosedRange<Int>]) in lines.map { ($0.lowerBound - 1)..<$0.upperBound }
    }
    let old = state.agreesOnRename(of: path, ends) ? ranges(lines.old) : []
    return (old, ranges(lines.new))
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
    draftSerial += 1
    let zone = PrCommentZone(subject: .draft, line: line + 1, fieldID: "draft:\(draftSerial)")
    zone.onPress = { [weak self] zone, control in self?.press(control, in: zone) }
    zone.onFieldFocus = { [weak self] zone, primary in
      guard let self, !primary, !zone.hasText, !zone.isWriting else { return }
      closeDraft(zone)
    }
    drafts.append(
      PrCommentPlacement(
        zone: zone, version: version, line: line, ends: placed.ends, basis: placed.shown))
    onRowsChange()
    zone.surface?.focus(zone.field)
  }

  private func closeDraft(_ zone: PrCommentZone) {
    guard let index = drafts.firstIndex(where: { $0.zone === zone }) else { return }
    drafts.remove(at: index)
    onRowsChange()
  }

  // MARK: - 押下と書き込み

  private func press(_ control: PrCommentControl, in zone: PrCommentZone) {
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
  /// 行を移している最中のスレッドへは書かない。
  private func write(_ write: GitHubReviewWrite, from zone: PrCommentZone, clears: Bool) {
    guard case .thread(let thread) = zone.subject, zone.canSend,
      !state.isWritingReview(.thread(thread.id))
    else { return }
    zone.failure = nil
    let accepted = state.writeReview(write) { [weak self, weak zone] failure in
      guard let self, let zone else { return }
      if let failure {
        zone.failure = PrPanelText.writeFailure(failure, language())
      } else if clears {
        zone.clearField()
      }
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
    zone.failure = nil
    zone.isWriting = true
    let write = GitHubReviewWrite.addThread(
      path: path, side: draft.version == .old ? .old : .new, line: draft.line + 1,
      commit: draft.ends.head, body: body)
    let accepted = state.writeReview(write) { [weak self, weak zone] failure in
      guard let self, let zone else { return }
      zone.isWriting = false
      if let failure {
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

/// 行の右端の印——並列の古い側の面の行とインラインの差し込んだ削除行では古い側の行、ほかでは新しい側の行に、新しいコメントの
/// 欄を開く。
extension PrCommentLayer: SurfaceTrailingMarkTarget {
  func surface(_ surface: any TextSurface, didPressTrailingMarkOn line: TrailingMarkLine) {
    switch line {
    case .document(let line):
      openDraft(oldSurface.map { $0 === surface } == true ? .old : .new, line: line)
    case .source(let line):
      openDraft(.old, line: line)
    }
  }
}
