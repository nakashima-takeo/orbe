import Foundation
import OrbeEditorCore

/// PR の diff のコメントの層——PR ごとの状態のスレッドを diff の行の下に置き、行の右端の印から新しいコメントの欄を開き、
/// 返信・解決・新しいスレッドの書き込みを PR ごとの状態へ頼む。PR の diff 1 つに 1 つ。
///
/// 返信と新しいコメントの書きかけは PR ごとの状態が持ち、層はそれを欄へ反映して、打った本文を書き戻す（→
/// `PrCommentLayer+Drafts`）。層が持つのは見せ方——スレッドの id → 絵の差し込み、開いている新しいコメントの欄と、返信の
/// 書きかけを持ったまま今の diff に置けなくなったスレッドの置き場所（`PrCommentPlacement`）、畳んでいるか、失敗の文。絵の
/// 差し込みはスレッドの id で使い回すので、読み直し・並びの置き直し・インライン ⇄ 並列をまたいで同じ欄が残る。スレッドを
/// 置くのは、diff が見せている両端の先頭のコミットで読んだスレッドだけ（古い版の行に付けない）。書き込みの失敗は頼んだ層へ
/// 返り、失敗の文を出す。diff の PR が diff の根の worktree の今の open の PR でない間は、新しいスレッドと返信を書かずに、
/// 送れる所を告げる。
@MainActor
final class PrCommentLayer {
  let pullRequest: EditorDiffPullRequest
  /// diff の根の worktree の今の PR（答えを読むだけで、見ている者にはならない——見ているのは PR のパネル）。未送信のレビューを
  /// 送れるのは、その PR を出すパネルだけ。
  private let current: BranchPullRequest
  /// 並びを置き直させる（スレッドの出入り・新しいコメントの欄の開閉・印を出せる行が分かった）。
  var onRowsChange: () -> Void = {}
  let language: () -> Language
  var threads: [String: PrCommentZone] = [:]
  /// スレッドを最後に置いた所（返信の書きかけを作るときの欄の位置と、読み直しが届くまでスレッドをその行に残すのに使う）。
  var lastPlaced: [String: PullRequestState.CommentSpot] = [:]
  /// 返信の書きかけを持ったまま今の diff に置けなくなったスレッドの置き場所。
  var held: [String: PrCommentPlacement] = [:]
  /// 新しいコメントの欄（書きかけの通し番号の順。開いた順でもある）。
  var drafts: [PrCommentPlacement] = []
  /// 見せるよう頼まれたスレッドと押したコメント（→ `PrCommentLayer+Reveal`）。
  var revealRequest: RevealRequest?
  /// 見せるよう頼まれた・頼まれたスレッドの、組み終えるのを待っていた絵の本文を組み終えた（diff が見せる）。
  var onRevealChange: () -> Void = {}
  /// 最後に並びへ注記を渡した回に載せたスレッドの絵と、その側と行（スレッドの id ごと。行を追う絵は、その回の置き場）。
  private(set) var shownThreads: [String: DiffRows.Zone] = [:]
  /// 求めた（求めている）印を出せる行の、両端と結果。
  private var commentable: (ends: PullRequestState.DiffEnds, lines: GitDiffHunkLines?)?
  /// 最後に並びへ注記を渡した両端とその両側の本文、並列の古い側の面（インラインでは nil）。
  private(set) var placed: Placed?
  /// 並びを置いている間（注記を渡してから、置いた面を知らされるまで）の、注記に載せた絵の差し込みと、その間に入力欄の主が
  /// 外れた絵の差し込み。並びを置き直すと、前の面は並びから外れた入力欄の場を閉じて主を本文へ戻す。欄が別の面へ移っただけなら
  /// 移った先で主のまま残すので、この間の「主が外れた」はその場で扱わず、置いた面が分かってから決める（→ `place`）。
  private var placing: (zones: [PrCommentZone], lost: [PrCommentZone])?
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
    let clock = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
      // main の runloop の timer なので main で届く。描き直しで作り直すのは時刻を載せる小さな層だけ（本文は組み直さない）。
      MainActor.assumeIsolated { self?.tick() }
    }
    RunLoop.main.add(clock, forMode: .common)
    self.clock = clock
    pullRequest.state.addCommentDraftsObserver(self)
  }

  deinit {
    let state = pullRequest.state
    clock?.invalidate()
    MainActor.assumeIsolated { state.removeCommentDraftsObserver(self) }
  }

  private func tick() {
    for zone in threads.values { zone.redraw() }
  }

  /// この PR が、diff の根の worktree の今の PR で open か。そうでない間（ブランチの切り替え・マージ・クローズの後）は、未送信の
  /// レビューに積む書き込み（新しいスレッド・返信）を断る——積んでも、Orbe から送る所が無い。
  var isCurrentPullRequest: Bool { current.state === state && state.isOpenPullRequest }

  var state: PullRequestState { pullRequest.state }
  var path: String { pullRequest.id.path }

  /// 裏の仕事（本文の組版・印を出せる行・欄の行の導き）が残っていない。
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

  /// diff が見せている両側の本文 `shown` の並びに混ぜる注記。PR ごとの書きかけのうち層にまだ無いものを欄にし、スレッドの値と
  /// 書き込みの最中かを絵の差し込みへ写し、見せている両端の先頭のコミットで読んだスレッドのうち今の diff に置けるもの
  /// （`PullRequestState.placement` が置けると答えるもの）と、行を追う欄（新しいコメントの欄と、返信の書きかけを持ったまま置けなくなったスレッド）を
  /// 置く。行を導いた両端が見せている両端と違う欄は、欄の起点から今の版の行を導き始める。見せている本文が前に注記を渡した本文のままなら、そのときの
  /// 両端で置く（出どころが新しい両端の本文を読み終えても、diff がそれを見せるまでは前の両端）。両端が分からなければ何も
  /// 置かない。
  func notes(shown: EditorDiff.SideTexts?) -> DiffRows.Notes {
    let notes = compose(shown: shown)
    placing = (notes.zones.compactMap { $0.zone as? PrCommentZone }, [])
    shownThreads = Dictionary(
      notes.zones.compactMap { placed in
        (placed.zone as? PrCommentZone)?.threadID.map { ($0, placed) }
      }, uniquingKeysWith: { first, _ in first })
    return notes
  }

  private func compose(shown: EditorDiff.SideTexts?) -> DiffRows.Notes {
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
    // マージベースの diff の行として読む）——置き方の決まりが答える（→ `PullRequestState.placement`・`kept`）。
    settleRevealRequest(ends: ends)
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
        guard state.placement(of: thread, shown: ends) == .placeable, let line = thread.line else {
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
        place(zone, at: spot, in: &notes)
      }
    } else {
      keepPlaced(current, language: language, in: &notes)
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
  /// 残すと置き方が答えるスレッド（`PullRequestState.keepsPlacement`）を、diff が見せている本文 `current` で最後に置いた行に
  /// 残す。ほかのスレッドと返信の書きかけは、置かない（書きかけがあれば、書きかけの欄の位置から行を追う）。
  private func keepPlaced(
    _ current: Placed, language: Language, in notes: inout DiffRows.Notes
  ) {
    let ordered = threads.sorted { a, b in
      (a.value.firstCommentTime, a.key) < (b.value.firstCommentTime, b.key)
    }
    for (id, zone) in ordered where held[id] == nil {
      guard let spot = lastPlaced[id], spot.basis == current.shown,
        case .thread(let thread) = zone.subject,
        state.keepsPlacement(of: thread, shown: current.ends)
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

  /// 今の diff に置けないスレッド `thread` に返信の書きかけがあれば、書きかけの欄の位置から行を追う（返信と解決は送れる）。
  /// 書きかけが無ければ置かない。
  private func hold(_ thread: GitHubPullRequestReview.Thread) {
    guard let zone = threads[thread.id], startHolding(thread.id, zone) else { return }
    zone.notice = .detached
    zone.update(.thread(thread))
    zone.isWriting = state.isWritingReview(.thread(thread.id))
  }

  /// レビューのやりとりから消えたスレッド `id` を手放す。返信の書きかけがあれば、書きかけの欄の位置から行を追って残し、削除
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

  /// スレッド `id` の絵の差し込み `zone` を、返信の書きかけの欄の位置（書きかけを作ったときにスレッドが置かれていた位置）を
  /// 起点に追い始める（追っていればそのまま）。どの層でも同じ起点なので、同じ行に出る。返信の書きかけが無ければ追わずに false。
  private func startHolding(_ id: String, _ zone: PrCommentZone) -> Bool {
    if held[id] != nil { return true }
    guard let spot = state.commentDrafts.replies[id]?.spot else { return false }
    zone.isCollapsed = false
    held[id] = PrCommentPlacement(zone: zone, origin: spot)
    return true
  }

  /// 並びを置いた面を絵の差し込みへ写す（`old` は並列の古い側の面。インラインなら nil で、どの差し込みも `new` に置く）。
  /// 並びに載せた入力欄が、主のまま別の面へ移った・置く間に主が外れたなら、置いた面で主にする（push を読んだ面の作り直し・
  /// 見せ方の切り替え）。並びに載らなかった入力欄の、置く間に外れた主は、ここで外れたものとして扱う。
  func place(old: (any TextSurface)?, new: any TextSurface) {
    oldSurface = old
    let (zones, lost) = placing ?? ([], [])
    placing = nil
    var moved: [PrCommentZone] = []
    func put(_ zone: PrCommentZone, on surface: any TextSurface) {
      if zone.isFieldPrimary, zone.surface !== surface { moved.append(zone) }
      zone.surface = surface
    }
    for zone in threads.values {
      guard case .thread(let thread) = zone.subject else { continue }
      put(zone, on: thread.side == .old ? old ?? new : new)
    }
    for placement in Array(held.values) + drafts {
      put(placement.zone, on: placement.version == .old ? old ?? new : new)
    }
    for zone in moved + lost {
      if zones.contains(where: { $0 === zone }) {
        zone.surface?.focus(zone.field)
      } else if !zone.isFieldPrimary {
        fieldDidLoseFocus(zone)
      }
    }
  }

  /// 主の入力欄が居る面（主の入力欄が無ければ nil）。
  var primaryFieldSurface: (any TextSurface)? {
    (Array(threads.values) + drafts.map(\.zone)).first(where: \.isFieldPrimary)?.surface
  }

  /// 絵の差し込み `zone` の入力欄が主になった・外れた。並びを置いている間に外れた主は、置いた面が分かるまで取っておく。
  func fieldFocusDidChange(_ zone: PrCommentZone, primary: Bool) {
    guard !primary else { return }
    guard placing == nil else {
      placing?.lost.append(zone)
      return
    }
    fieldDidLoseFocus(zone)
  }

  /// 絵の差し込み `zone` の入力欄の主が外れた。空の新しいコメントの欄は閉じ、置けなくなった・削除されたスレッドは、返信の
  /// 書きかけを空にして主が外れたら手放す。
  private func fieldDidLoseFocus(_ zone: PrCommentZone) {
    guard !zone.hasText else { return }
    switch zone.subject {
    case .thread(let thread):
      guard release(thread.id, zone) else { return }
      onRowsChange()
    case .draft:
      guard !zone.isWriting else { return }
      closeDraft(zone)
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
