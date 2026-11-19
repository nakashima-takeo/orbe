import Foundation
import OrbeEditorCore

/// PR の diff のコメントの層——PR ごとの状態のスレッドを diff の行の下に置き、行の右端の印から新しいコメントの欄を開き、
/// 返信・解決・新しいスレッドの書き込みを PR ごとの状態へ頼む。PR の diff タブ 1 つに 1 つ。
///
/// 層が持つのはタブごとの見せ方——スレッドの id → 絵の差し込み、開いている新しいコメントの欄（diff の先頭のコミット・側・行
/// ごと）、畳んでいるか。絵の差し込みはスレッドの id で使い回すので、返信の書きかけは読み直し・並びの置き直し・インライン ⇄
/// 並列をまたいで残る。スレッドを置くのは、diff が見せている両端の先頭のコミットで読んだスレッドだけ（古い版の行に付けない）。
/// 書き込みの結果は頼んだ層へ返り、通れば欄を空にし（新しいコメントの欄は閉じ）、通らなければ本文を残して失敗の文を出す——
/// 同じ PR の別のタブの書きかけは変わらない。
@MainActor
final class PrCommentLayer {
  let pullRequest: EditorDiffPullRequest
  /// 並びを置き直させる（スレッドの出入り・新しいコメントの欄の開閉・印を出せる行が分かった）。
  var onRowsChange: () -> Void = {}
  private let language: () -> Language
  private var threads: [String: PrCommentZone] = [:]
  private var drafts: [Draft: PrCommentZone] = [:]
  /// 開いた順の新しいコメントの欄。
  private var draftOrder: [Draft] = []
  /// 求めた（求めている）印を出せる行の、両端と答え。
  private var commentable: (ends: PullRequestState.DiffEnds, lines: GitDiffHunkLines?)?
  /// 最後に並びへ注記を渡した両端と、並列の古い側の面（インラインでは nil）。
  private var placedEnds: PullRequestState.DiffEnds?
  private weak var oldSurface: (any TextSurface)?

  /// 新しいコメントの欄の場所——行を数えた diff の先頭のコミット・側・行（0 始まり）。
  struct Draft: Hashable {
    let head: String
    let version: DiffRows.Version
    let line: Int
  }

  init(pullRequest: EditorDiffPullRequest, language: @escaping () -> Language) {
    self.pullRequest = pullRequest
    self.language = language
  }

  var state: PullRequestState { pullRequest.state }
  var path: String { pullRequest.id.path }

  /// 裏の仕事（本文の測り・印を出せる行）が残っていない。
  var isSettled: Bool {
    !threads.values.contains(where: \.isMeasuring)
      && (placedEnds == nil || commentable?.lines != nil)
  }

  /// スレッド `id` の絵の差し込み（まだ置いていなければ nil）。
  func zone(thread id: String) -> PrCommentZone? { threads[id] }

  /// 今の両端で開いている、側 `version` の行 `line`（0 始まり）の新しいコメントの欄。
  func draft(_ version: DiffRows.Version, line: Int) -> PrCommentZone? {
    guard let head = placedEnds?.head else { return nil }
    return drafts[Draft(head: head, version: version, line: line)]
  }

  // MARK: - 並び

  /// diff が見せている両側の本文 `shown` の並びに混ぜる注記。スレッドの値と書き込みの最中かを絵の差し込みへ写し、見せている
  /// 両端の先頭のコミットで読んだスレッドと、その先頭のコミットで開いた新しいコメントの欄を置く。両端が分からなければ何も
  /// 置かない。
  func notes(shown: EditorDiff.SideTexts?) -> DiffRows.Notes {
    guard let shown, let ends = pullRequest.ends(of: shown) else {
      placedEnds = nil
      return DiffRows.Notes()
    }
    placedEnds = ends
    let language = language()
    let visible = (state.threads(at: ends.head) ?? [])
      .compactMap { thread in thread.line.map { (thread, $0) } }
      .filter { $0.0.path == path }
      .sorted { a, b in
        (a.0.side == .old ? 0 : 1, a.1, a.0.comments.first?.createdAt ?? .distantPast, a.0.id)
          < (b.0.side == .old ? 0 : 1, b.1, b.0.comments.first?.createdAt ?? .distantPast, b.0.id)
      }
    var notes = DiffRows.Notes()
    for (thread, line) in visible {
      let zone = zone(for: thread, line: line)
      zone.language = language
      zone.isWriting = state.isWritingReview(.thread(thread.id))
      let version = Self.version(thread.side)
      notes.zones.append(DiffRows.Zone(version: version, line: line - 1, zone: zone))
      switch version {
      case .old: notes.threads.old.insert(line - 1)
      case .new: notes.threads.new.insert(line - 1)
      }
    }
    for key in draftOrder where key.head != ends.head { closeDraft(key, reapply: false) }
    for key in draftOrder {
      guard let zone = drafts[key] else { continue }
      zone.language = language
      let index =
        notes.zones.lastIndex {
          Self.order($0.version, $0.line) <= Self.order(key.version, key.line)
        }.map { $0 + 1 } ?? 0
      notes.zones.insert(DiffRows.Zone(version: key.version, line: key.line, zone: zone), at: index)
    }
    notes.commentable = commentableLines(ends)
    return notes
  }

  /// 並びを置いた面を絵の差し込みへ写す（`old` は並列の古い側の面。インラインなら nil で、どの差し込みも `new` に置く）。
  func place(old: (any TextSurface)?, new: any TextSurface) {
    oldSurface = old
    for zone in threads.values {
      guard case .thread(let thread) = zone.subject else { continue }
      zone.surface = thread.side == .old ? old ?? new : new
    }
    for (key, zone) in drafts { zone.surface = key.version == .old ? old ?? new : new }
  }

  private static func version(_ side: GitHubDiffSide) -> DiffRows.Version {
    side == .old ? .old : .new
  }

  private static func order(_ version: DiffRows.Version, _ line: Int) -> (Int, Int) {
    (version == .old ? 0 : 1, line)
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
    let renamed = state.content?.files.first { $0.path == path }?.change == .renamed
    let old = renamed == (ends.renames[path] != nil) ? ranges(lines.old) : []
    return (old, ranges(lines.new))
  }

  // MARK: - 新しいコメントの欄

  /// 側 `version` の行 `line`（0 始まり）の下に新しいコメントの欄を開き、焦点を入れる（開いていれば焦点だけ入れる）。
  func openDraft(_ version: DiffRows.Version, line: Int) {
    guard let ends = placedEnds else { return }
    let key = Draft(head: ends.head, version: version, line: line)
    if let zone = drafts[key] {
      zone.surface?.focus(zone.field)
      return
    }
    let zone = PrCommentZone(
      subject: .draft, line: line + 1, fieldID: "draft:\(ends.head):\(version):\(line)")
    zone.onPress = { [weak self] zone, control in self?.press(control, in: zone) }
    zone.onFieldFocus = { [weak self] zone, primary in
      guard let self, !primary, zone.text.isEmpty, !zone.isWriting,
        let key = drafts.first(where: { $0.value === zone })?.key
      else { return }
      closeDraft(key, reapply: true)
    }
    drafts[key] = zone
    draftOrder.append(key)
    onRowsChange()
    zone.surface?.focus(zone.field)
  }

  private func closeDraft(_ key: Draft, reapply: Bool) {
    guard drafts.removeValue(forKey: key) != nil else { return }
    draftOrder.removeAll { $0 == key }
    if reapply { onRowsChange() }
  }

  // MARK: - 押下と書き込み

  private func press(_ control: PrCommentControl, in zone: PrCommentZone) {
    let body = zone.text
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
      guard !body.isEmpty, !zone.isWriting,
        let key = drafts.first(where: { $0.value === zone })?.key
      else { return }
      writeDraft(key, body: body, zone: zone)
    case (.draft, .cancel):
      guard !zone.isWriting, let key = drafts.first(where: { $0.value === zone })?.key else {
        return
      }
      closeDraft(key, reapply: true)
    default: return
    }
  }

  /// スレッドへの書き込みを頼む。同じスレッドへの書き込みが走っていれば何もしない（2 回押しても 1 回）。
  private func write(_ write: GitHubReviewWrite, from zone: PrCommentZone, clears: Bool) {
    guard case .thread(let thread) = zone.subject,
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
  private func writeDraft(_ key: Draft, body: String, zone: PrCommentZone) {
    zone.failure = nil
    zone.isWriting = true
    let write = GitHubReviewWrite.addThread(
      path: path, side: key.version == .old ? .old : .new, line: key.line + 1, commit: key.head,
      body: body)
    let accepted = state.writeReview(write) { [weak self, weak zone] failure in
      guard let self, let zone else { return }
      zone.isWriting = false
      if let failure {
        zone.failure = PrPanelText.writeFailure(failure, language())
        return
      }
      zone.clearField()
      closeDraft(key, reapply: true)
    }
    if !accepted {
      zone.isWriting = false
      zone.failure = L10n.string(.editorPrThreadNotReady, language())
    }
  }
}

/// 行の右端の印——並列の古い側の面の行と、インラインの差し込んだ削除行は古い側、ほかは新しい側の行に新しいコメントの欄を開く。
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
