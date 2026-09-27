import Foundation
import OrbeEditorCore
import os

/// 開いている文書——保存前の中身を探し、結果の鮮度を文書の版で持つ。範囲に入る開いている文書ごとに「結果が映している版」
/// （`searchedVersions`。頼んでまだ届いていない版を含む）を持ち、届いた結果の版が今の文書の版より古ければ捨ててその場で
/// 今の写しで頼み直す（検索の最中に編集しても、その文書の結果は消えない）。
///
/// 取り直しのきっかけは 2 つ——焦点の文書の打鍵（pane が本文の変化を渡す）と外部変更（根のサービスの観測者として）。どちらも
/// 250ms 後に、結果に出ているその文書だけを取り直す。面が見えたときと文書が焦点に来たときは、映している版と文書の版を比べ直す。
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

  /// 届いたまとまりを置く。開いている文書のまとまりは、届いた版が今の文書の版と同じときだけ置き、古ければ頼み直す。
  func accept(_ file: SearchFileMatches) {
    guard let span = file.document, let document = document(at: file.path) else {
      results.set(file)
      return
    }
    guard span.version == document.version else {
      refresh(file.path)
      return
    }
    searchedVersions[file.path] = span.version
    results.set(file)
  }

  /// 焦点の文書の本文が変わった。まとまりの区間をずらし、結果に出ていれば 250ms 後に取り直す。行は一致が落ちたとき
  /// だけ作り直す（行が見せるプレビューは取り直すまで変わらない——打鍵のたびに全部の行を作り直さない）。
  func documentDidEdit(_ document: EditorDocument, _ edit: TextEdit) {
    guard let path = relativePath(of: document), let before = results[path]?.count else { return }
    results.track(path, edit, version: document.version)
    if results[path]?.count == before { onGroundChange() } else { resultsDidChange() }
    scheduleRefresh(path)
  }

  /// 文書を見せた（焦点に来た・開いた）。ディスクのまとまりしか無ければ開いた写しの区間に直し、映している版が古ければ
  /// 取り直す。
  func documentDidShow(_ document: EditorDocument) {
    guard let path = relativePath(of: document), let file = results[path] else { return }
    if file.document == nil {
      results.attach(path, to: document.text, version: document.version)
      searchedVersions[path] = document.version
      resultsDidChange()
    } else if searchedVersions[path] != document.version {
      refresh(path)
    }
  }

  /// 一致の文書の区間（ディスクのまとまりなら開いた写しの区間に直してから）。
  func range(of id: RowID, in document: EditorDocument) -> NSRange? {
    guard let match = id.match else { return nil }
    documentDidShow(document)
    guard let span = results[id.path]?.document, span.version == document.version,
      match < span.ranges.count
    else { return nil }
    return span.ranges[match]
  }

  /// 焦点の文書に敷く一致の地——そのまとまりの区間と、選んだ一致。区間が今の本文のものでなければ出さない。
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
          self.accept(file)
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
