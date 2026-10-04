import Foundation
import OrbeEditorCore
import os

/// 開いている文書——保存前の中身を探し、結果の鮮度を文書の版で持つ。範囲に入る開いている文書ごとに「結果が映している版」
/// （`searchedVersions`。頼んでまだ届いていない版を含む）を持ち、届いた結果の版が今の文書の版より古ければ捨ててその場で
/// 今の写しで頼み直す（検索の最中に編集しても、その文書の結果は消えない）。
///
/// 取り直しのきっかけは 2 つ——焦点の文書の打鍵（pane が本文の変化を渡す）と外部変更（根のサービスの観測者として）。どちらも
/// 250ms 後に、結果に出ているその文書だけを取り直す。面が見えたときと文書が焦点に来たときは、映している版と文書の版を比べ直す
/// （文書を見せたときは区間の字も今の本文と照合する）。
/// 焦点の文書の編集では、まとまりの区間を自分でずらす（取り直しまでの間の地と「押して開く」が同じ区間を使う）。
extension ProjectSearch: RootFilesObserver {
  static let refreshDelay: TimeInterval = 0.25

  /// 根の下で既定の除外に当たらない開いている文書の写しと版。
  func searchableDocuments() -> [ProjectSearchRun.Document] {
    documents().compactMap { document in
      guard let path = relativePath(of: document) else { return nil }
      return ProjectSearchRun.Document(path: path, text: document.text, version: document.version)
    }
  }

  /// 文書の根からの相対パス（根の外・既定の除外なら nil）。
  func relativePath(of document: EditorDocument) -> String? {
    let path = GitWorktreeRoot.normalizedPath(document.url.path)
    guard path.hasPrefix(root + "/") else { return nil }
    let relative = String(path.dropFirst(root.count + 1))
    return GitGrep.isExcluded(relative) ? nil : relative
  }

  func document(at path: String) -> EditorDocument? {
    documents().first { relativePath(of: $0) == path }
  }

  /// 届いたまとまりの列（パスの順）を置く。開いている文書のまとまりは、届いた版が今の文書の版と同じときだけ置き、古ければ
  /// 頼み直す。同じパスは開いている文書が勝つ——ディスクのまとまりのパスを開いていれば置かず、検索の途中で開いた文書なら
  /// その場で文書から探し直す。
  func accept(_ files: [SearchFileMatches]) {
    let open = openDocuments()
    var kept: [SearchFileMatches] = []
    kept.reserveCapacity(files.count)
    for file in files {
      guard let document = open[file.path] else {
        kept.append(file)
        continue
      }
      if let span = file.document, span.version == document.version {
        searchedVersions[file.path] = span.version
        kept.append(file)
      } else if file.document != nil || searchedVersions[file.path] == nil {
        refresh(file.path)
      }
    }
    results.set(sorted: kept)
  }

  /// 範囲に入る開いている文書（根からの相対パスごと）。
  private func openDocuments() -> [String: EditorDocument] {
    var open: [String: EditorDocument] = [:]
    for document in documents() {
      if let path = relativePath(of: document) { open[path] = document }
    }
    return open
  }

  /// 焦点の文書の本文が変わった（適用した順の編集の列）。まとまりの区間をずらし、結果に出ていれば 250ms 後に取り直す。
  /// 行は一致が落ちたときだけ作り直す（行が見せるプレビューは取り直すまで変わらない——打鍵のたびに全部の行を作り直さない）。
  func documentDidEdit(_ document: EditorDocument, _ edits: [VersionedEdit]) {
    guard let path = relativePath(of: document), let before = results[path]?.count else { return }
    trackAnchor(path, edits.map(\.edit))
    if let version = edits.last?.version {
      results.track(path, EditSweep.batches(applied: edits.map(\.edit)), version: version)
    }
    if results[path]?.count == before { onGroundChange() } else { resultsDidChange() }
    scheduleRefresh(path)
  }

  /// 文書を見せた（焦点に来た・開いた）。ディスクのまとまりしか無ければ開いた写しの区間に直し、映している版が古ければ
  /// 取り直す。版が同じでも区間の字を今の本文と照合する——ディスクの結果は探した後に外で書き換わることがあり、閉じて開き直した
  /// 文書は版を 0 から数え直すので、版だけでは区間が今の本文のものか分からない。字の違う一致は落として（無関係な字を選ばない・
  /// 地を敷かない）その文書を取り直す。字が合えばその場の区間をそのまま使う（開いた直後に一致を選んで中央へ送れる）。
  func documentDidShow(_ document: EditorDocument) {
    guard let path = relativePath(of: document), let file = results[path] else { return }
    if file.document == nil {
      let dropped = results.attach(path, to: document.text, version: document.version)
      searchedVersions[path] = document.version
      resultsDidChange()
      if dropped { refresh(path) }
    } else if searchedVersions[path] != document.version {
      refresh(path)
    } else if results.dropDisagreeing(path, with: document.text) {
      resultsDidChange()
      refresh(path)
    }
  }

  /// 焦点の文書に敷く一致の地——そのまとまりの区間と、選んだ一致（開いた一致を置く区間でもある）。区間が今の本文の
  /// ものでなければ出さない。
  func ground(for document: EditorDocument) -> (ranges: [NSRange], current: NSRange?) {
    guard let path = relativePath(of: document), let span = results[path]?.document,
      span.version == document.version
    else { return ([], nil) }
    let current = selection.flatMap { selection -> NSRange? in
      guard selection.path == path, let match = selection.match, match < span.ranges.count
      else { return nil }
      return span.ranges[match]
    }
    return (span.ranges, current)
  }

  private func scheduleRefresh(_ path: String) {
    let delay = refreshDelays[path] ?? EditorDelay()
    refreshDelays[path] = delay
    delay.run(after: Self.refreshDelay) { [weak self] in self?.refresh(path) }
  }

  /// 開いている文書 1 つを今の写しで探し直す（裏で）。同じ文書の前の取り直しは止める。届いたら `accept` が版を見る。
  func refresh(_ path: String) {
    refreshDelays[path]?.cancel()
    refreshCancels[path]?.withLock { $0 = true }
    guard let compiled, let document = document(at: path) else { return }
    let text = document.text
    let version = document.version
    let current = generation
    let cancelled = OSAllocatedUnfairLock(initialState: false)
    refreshCancels[path] = cancelled
    searchedVersions[path] = version
    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
      guard
        let found = LineMatches.search(
          text, compiled.regex, limit: ProjectSearchResults.limit,
          isCancelled: { cancelled.withLock { $0 } })
      else { return }
      let file = SearchFileMatches(
        path: path, matches: found.matches,
        document: .init(ranges: found.ranges, version: version))
      DispatchQueue.main.async {
        MainActor.assumeIsolated {
          guard let self, current == self.generation, !cancelled.withLock({ $0 }) else { return }
          self.accept([file])
          self.resultsDidChange()
        }
      }
    }
  }

  /// 取り直しの予約と、走っている取り直しを止める（検索し直す・結果を消す）。
  func cancelRefreshes() {
    for delay in refreshDelays.values { delay.cancel() }
    refreshDelays = [:]
    for cancelled in refreshCancels.values { cancelled.withLock { $0 = true } }
    refreshCancels = [:]
  }

  /// 映している版が文書の版と違う開いている文書を取り直す。
  func revalidate() {
    for document in documents() {
      guard let path = relativePath(of: document), results.index(of: path) != nil,
        let searched = searchedVersions[path], searched != document.version
      else { continue }
      refresh(path)
    }
  }

  func liveDidChange() {
    if isLive {
      let files = RootFiles.shared(for: root)
      self.files = files
      files.addObserver(self)
      revalidate()
    } else {
      files?.removeObserver(self)
      files = nil
    }
  }

  // MARK: - RootFilesObserver

  /// 外部変更。変わったパスが結果に出ている開いている文書なら 250ms 後に取り直す（文書の差し替えは文書の結線が先に
  /// 済ませる。250ms 後に版を読むので、観測者の呼ばれる順に依らない）。
  func rootFiles(_ files: RootFiles, filesDidChange change: RootFiles.Change) {
    for document in documents() {
      guard let path = relativePath(of: document), results.index(of: path) != nil,
        change.includes(root + "/" + path)
      else { continue }
      scheduleRefresh(path)
    }
  }

  func rootFilesStatusDidChange(_ files: RootFiles) {}

  func rootFiles(_ files: RootFiles, baselineDidChange url: URL) {}
}
