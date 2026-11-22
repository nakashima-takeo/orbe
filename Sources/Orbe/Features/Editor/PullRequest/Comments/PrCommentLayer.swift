import Foundation
import OrbeEditorCore

/// PR の diff のコメントの層——PR ごとの状態のスレッドを diff の行の下に置き、行の右端の印から新しいコメントの欄を開き、
/// 返信・解決・新しいスレッドの書き込みを PR ごとの状態へ頼む。PR の diff タブ 1 つに 1 つ。
///
/// 返信と新しいコメントの書きかけは PR ごとの状態が持ち、層はそれを欄へ反映して、打った本文を書き戻す（→
/// `PrCommentLayer+Drafts`）。層が持つのは見せ方——スレッドの id → 絵の差し込み、開いている新しいコメントの欄と、返信の
/// 書きかけを持ったまま今の diff に置けなくなったスレッドの置き場所（`PrCommentPlacement`）、畳んでいるか、失敗の文。絵の
/// 差し込みはスレッドの id で使い回すので、読み直し・並びの置き直し・インライン ⇄ 並列をまたいで同じ欄が残る。スレッドを
/// 置くのは、diff が見せている両端の先頭のコミットで読んだスレッドだけ（古い版の行に付けない）。書き込みの失敗は頼んだ層へ
/// 返り、失敗の文を出す。タブの PR がタブの根の worktree の今の open の PR でない間は、新しいスレッドと返信を書かずに、
/// 送れる所を告げる。
@MainActor
final class PrCommentLayer {
  let pullRequest: EditorDiffPullRequest
  /// タブの根の worktree の今の PR（タブがある間見る）。保留中のレビューを送れるのは、その PR を出すパネルだけ。
  private let current: BranchPullRequest
  /// 並びを置き直させる（スレッドの出入り・新しいコメントの欄の開閉・印を出せる行が分かった）。
  var onRowsChange: () -> Void = {}
  /// 書きかけがあるか（`holdsDrafts`）が変わったかもしれない（入力欄に空白でない字が入った・無くなった）。
  var onDraftChange: () -> Void = {}
  let language: () -> Language
  var threads: [String: PrCommentZone] = [:]
  /// スレッドを最後に置いた所（今の diff に置けなくなったときに、行を追い始める所）。
  var lastPlaced: [String: PullRequestState.CommentSpot] = [:]
  /// 返信の書きかけを持ったまま今の diff に置けなくなったスレッドの置き場所。
  var held: [String: PrCommentPlacement] = [:]
  /// 新しいコメントの欄（書きかけの通し番号の順。開いた順でもある）。
  var drafts: [PrCommentPlacement] = []
  /// 求めた（求めている）印を出せる行の、両端と結果。
  private var commentable: (ends: PullRequestState.DiffEnds, lines: GitDiffHunkLines?)?
  /// 最後に並びへ注記を渡した両端とその両側の本文、並列の古い側の面（インラインでは nil）。
  private(set) var placed: Placed?
  private weak var oldSurface: (any TextSurface)?
  /// スレッドの絵を 1 分ごとに描き直させる（コメントの相対時刻を、時の経過に合わせて進める）。
  private var clock: Timer?

  /// diff の両端と両側の本文。
  struct Placed: Equatable {
    let ends: PullRequestState.DiffEnds
    let shown: EditorDiff.SideTexts
  }

  init(pullRequest: EditorDiffPullRequest, language: @escaping () -> Language) {
    self.pullRequest = pullRequest
    self.language = language
    current = BranchPullRequest.shared(
      for: pullRequest.id.root, source: pullRequest.state.source)
    current.beginWatching()
    let clock = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
      // main の runloop の timer なので main で届く。描き直しで作り直すのは時刻を載せる小さな層だけ（本文は組み直さない）。
      MainActor.assumeIsolated { self?.tick() }
    }
    RunLoop.main.add(clock, forMode: .common)
    self.clock = clock
    pullRequest.state.addCommentDraftsObserver(self)
  }

  deinit {
    let current = current
    let state = pullRequest.state
    clock?.invalidate()
    MainActor.assumeIsolated {
      current.endWatching()
      state.removeCommentDraftsObserver(self)
    }
  }

  private func tick() {
    for zone in threads.values { zone.redraw() }
  }

  /// この PR が、タブの根の worktree の今の PR で open か。そうでない間（ブランチの切り替え・マージ・クローズの後）は、保留中の
  /// レビューに積む書き込み（新しいスレッド・返信）を断る——積んでも、Orbe から送る所が無い。
  var isCurrentPullRequest: Bool { current.state === state && state.content?.state == .open }

  var state: PullRequestState { pullRequest.state }
  var path: String { pullRequest.id.path }

  /// 裏の仕事（本文の組版・印を出せる行・欄の行の移し）が残っていない。
  var isSettled: Bool {
    !threads.values.contains(where: \.isTypesetting) && drafts.allSatisfy(\.isSettled)
      && held.values.allSatisfy(\.isSettled) && (placed == nil || commentable?.lines != nil)
  }

  /// このファイルへの返信か新しいコメントに、空白でない字の書きかけがある（人が打った内容——仮のタブを普通のタブにする。
  /// 書きかけを残した PR の diff は、開き直すとはじめから普通のタブになる）。
  var holdsDrafts: Bool {
    let stored = state.commentDrafts
    return stored.replies.values.contains {
      $0.thread.path == path && PrCommentZone.hasText($0.body)
    }
      || stored.comments.values.contains { $0.path == path && PrCommentZone.hasText($0.body) }
  }

  /// スレッド `id` の絵の差し込み（まだ置いていなければ nil）。
  func zone(thread id: String) -> PrCommentZone? { threads[id] }

  /// 側 `version` の行 `line`（0 始まり）に置いている新しいコメントの欄（行が現在の diff に無い欄を含む）。
  func draft(_ version: DiffRows.Version, line: Int) -> PrCommentZone? {
    drafts.first { $0.version == version && $0.line == line }?.zone
  }

  // MARK: - 並び

  /// diff が見せている両側の本文 `shown` の並びに混ぜる注記。PR ごとの書きかけのうち層にまだ無いものを欄にし、スレッドの値と
  /// 書き込みの最中かを絵の差し込みへ写し、見せている両端の先頭のコミットで読んだスレッドのうち今の diff に置けるもの
  /// （`PullRequestState.canPlace`）と、行を追う欄（新しいコメントの欄と、返信の書きかけを持ったまま置けなくなったスレッド）を
  /// 置く。別の両端で行を数えた欄は、行を今の版へ移し始める。見せている本文が前に注記を渡した本文のままなら、そのときの
  /// 両端で置く（出どころが新しい両端の本文を読み終えても、diff がそれを見せるまでは前の両端）。両端が分からなければ何も
  /// 置かない。
  func notes(shown: EditorDiff.SideTexts?) -> DiffRows.Notes {
    guard let shown,
      let ends = pullRequest.ends(of: shown) ?? (placed?.shown == shown ? placed?.ends : nil)
    else {
      placed = nil
      return DiffRows.Notes()
    }
    let current = Placed(ends: ends, shown: shown)
    placed = current
    let language = language()
    var notes = DiffRows.Notes()
    let markable = commentableLines(ends)
    notes.commentable = markable ?? ([], [])
    adoptDrafts()
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
        let spot = PullRequestState.CommentSpot(
          side: thread.side, line: line - 1, ends: ends, basis: shown)
        lastPlaced[thread.id] = spot
        state.placeReply(to: thread, at: spot)
        place(zone, at: spot, in: &notes)
      }
    } else {
      keepPlaced(current, isCurrent: isCurrent, language: language, in: &notes)
    }
    placeFollowing(current, commentable: markable, language: language, in: &notes)
    return notes
  }

  /// 行を追う欄（返信の書きかけを持ったまま置けなくなったスレッドと、新しいコメントの欄）を、diff が見せている両端と本文
  /// `current` に合わせて置く。
  private func placeFollowing(
    _ current: Placed, commentable: (old: [Range<Int>], new: [Range<Int>])?,
    language: Language, in notes: inout DiffRows.Notes
  ) {
    let following =
      held.sorted { a, b in
        let (x, y) = (a.value.zone.firstCommentTime, b.value.zone.firstCommentTime)
        return (x, a.key) < (y, b.key)
      }.map(\.value) + drafts
    let ends = current.ends
    let shown = current.shown
    for placement in following {
      placement.follow(ends, shown: shown, commentable: commentable) { [weak self] in
        self?.onRowsChange()
      }
      if let serial = placement.zone.draftSerial {
        placement.zone.notice = placement.isGone ? .lineGone : nil
        placement.zone.isWriting = state.isWritingReview(.comment(serial))
      }
      placement.zone.language = language
      notes.zones.append(
        DiffRows.Zone(version: placement.version, line: placement.line, zone: placement.zone))
    }
  }

  /// レビューのやりとりが、diff が見せている先頭と違う先頭を読んだ間（PR への push を読み、diff が新しい両端を見せるまで）は、
  /// diff が見せている両端と本文 `current` で最後に置いたスレッドを、その行に残す（古い側の行のスレッドは、両端が PR の今の
  /// 両端の間だけ）。ほかの返信の書きかけは、最後に置いた所から行を追う。
  private func keepPlaced(
    _ current: Placed, isCurrent: Bool, language: Language, in notes: inout DiffRows.Notes
  ) {
    let ordered = threads.sorted { a, b in
      (a.value.firstCommentTime, a.key) < (b.value.firstCommentTime, b.key)
    }
    for (id, zone) in ordered where held[id] == nil {
      guard let spot = lastPlaced[id], spot.ends == current.ends, spot.basis == current.shown,
        isCurrent || spot.side == .new
      else {
        _ = startHolding(id, zone)
        continue
      }
      zone.language = language
      zone.isWriting = state.isWritingReview(.thread(id))
      place(zone, at: spot, in: &notes)
    }
  }

  /// スレッドの絵の差し込み `zone` を、置いた所 `spot` の行の下に置き、その行に印を付ける。
  private func place(
    _ zone: PrCommentZone, at spot: PullRequestState.CommentSpot, in notes: inout DiffRows.Notes
  ) {
    let version = Self.version(spot.side)
    notes.zones.append(DiffRows.Zone(version: version, line: spot.line, zone: zone))
    switch version {
    case .old: notes.threads.old.insert(spot.line)
    case .new: notes.threads.new.insert(spot.line)
    }
  }

  /// 今の diff に置けないスレッド `thread` に返信の書きかけがあれば、最後に置いた所から行を追う（返信と解決は送れる）。
  /// 書きかけが無ければ置かない。
  private func hold(_ thread: GitHubPullRequestReview.Thread) {
    guard let zone = threads[thread.id], startHolding(thread.id, zone),
      let placement = held[thread.id]
    else { return }
    zone.notice = .detached
    zone.update(.thread(thread))
    zone.isWriting = state.isWritingReview(.thread(thread.id))
    state.placeReply(to: thread, at: placement.spot)
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

  /// スレッド `id` の絵の差し込み `zone` を、最後に置いた所（この層で置いていなければ、書きかけの欄の位置）から追い始める
  /// （追っていればそのまま）。返信の書きかけが無ければ追わずに false。
  private func startHolding(_ id: String, _ zone: PrCommentZone) -> Bool {
    if held[id] != nil { return true }
    guard zone.hasText, let spot = lastPlaced[id] ?? state.commentDrafts.replies[id]?.spot
    else { return false }
    zone.isCollapsed = false
    let placement = PrCommentPlacement(zone: zone, spot: spot)
    placement.onMove = { [weak self] placement in
      guard case .thread(let thread) = placement.zone.subject else { return }
      self?.state.placeReply(to: thread, at: placement.spot)
    }
    held[id] = placement
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

  /// スレッド `thread` の絵の差し込み（無ければ、返信の書きかけの本文で作る）。
  private func zone(for thread: GitHubPullRequestReview.Thread, line: Int)
    -> PrCommentZone
  {
    if let zone = threads[thread.id] {
      zone.line = line
      zone.update(.thread(thread))
      return zone
    }
    return makeZone(thread, line: line)
  }

  /// 両端 `ends` の、印を出せる行（0 始まりの半開区間）。まだ求めていなければ裏で求め始めて nil を返し、求め終えたら並びを
  /// 置き直させる。rename の判定が GitHub と手元で食い違うファイルでは、古い側の行に印を出さない（古い側の行の対応が変わる）。
  private func commentableLines(_ ends: PullRequestState.DiffEnds)
    -> (old: [Range<Int>], new: [Range<Int>])?
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
    guard let lines = commentable?.lines else { return nil }
    let ranges = { (lines: [ClosedRange<Int>]) in lines.map { ($0.lowerBound - 1)..<$0.upperBound }
    }
    let old = state.agreesOnRename(of: path, ends) ? ranges(lines.old) : []
    return (old, ranges(lines.new))
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
