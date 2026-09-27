import Foundation
import OrbeEditorCore
import os

/// プロジェクト検索 1 回ぶんの裏の仕事。開いている文書の写しを先に探し（保存前の中身）、続けて git grep を流しながら読んで
/// ディスクのファイルを探す（開いている文書のパスの行は捨てる）。git は一致した行を送り、その行の中の一致の位置は同じ問いの
/// ICU の式が取る（ICU で 1 つも取れない行は結果にしない）。結果はファイルごとのまとまりで、裏でパスの順に並べておき、main へは
/// 80ms ごとにまとめて渡し、終わりはすぐ渡す（main は並んだ列を併合するだけ）。一致の総数が上限に達したら git を止めて
/// 終える。止める（`cancel`）と以後は何も渡さない。
/// 状態はロックの中にだけあり、`GitRunner` はスレッドをまたいで使う前提の型なので、裏のスレッドへ渡してよい。
final class ProjectSearchRun: @unchecked Sendable {
  /// 探す開いている文書（根からの相対パス・写し・版）。
  struct Document: Sendable {
    let path: String
    let text: TextRope
    let version: Int
  }

  /// main へ渡す 1 回ぶん。`files` はパスの順。`finished` なら最後で、`error` はディスク側が始められなかった・断った理由。
  struct Batch: Sendable {
    var files: [SearchFileMatches] = []
    var finished = false
    var error: GitGrep.Failure?
  }

  static let batchInterval: TimeInterval = 0.08

  private struct State: Sendable {
    var pending = Batch()
    var flushScheduled = false
    var cancelled = false
    var total = 0
    var stoppedAtLimit = false
    /// git の出力の解析と、読みかけのファイルのまとまり。
    var parser = GitGrep.Parser()
    var current: (path: String, matches: [SearchMatch])?
  }

  private let query: CompiledSearchQuery
  private let root: String
  private let documents: [Document]
  private let runner: GitRunner
  private let deliver: @MainActor @Sendable (Batch) -> Void
  private let state = OSAllocatedUnfairLock(initialState: State())
  private let stream = OSAllocatedUnfairLock<GitRunner.Stream?>(initialState: nil)

  init(
    query: CompiledSearchQuery, root: String, documents: [Document], runner: GitRunner,
    deliver: @escaping @MainActor @Sendable (Batch) -> Void
  ) {
    self.query = query
    self.root = root
    self.documents = documents
    self.runner = runner
    self.deliver = deliver
  }

  func start() {
    DispatchQueue.global(qos: .userInitiated).async { [self] in
      searchDocuments()
      guard !isCancelled, !reachedLimit else {
        finish(error: nil)
        return
      }
      let skipped = Set(documents.map(\.path))
      let handle = runner.stream(
        GitGrep.arguments(pattern: query.pcre), cwd: root, environment: GitGrep.environment,
        onOutput: { [self] data in receive(data, skipping: skipped) },
        completion: { [self] output in
          flushCurrent()
          finish(error: GitGrep.failure(of: output))
        })
      stream.withLock { $0 = handle }
      if isCancelled { handle.cancel() }
    }
  }

  func cancel() {
    state.withLock { $0.cancelled = true }
    stream.withLock { $0 }?.cancel()
  }

  private var isCancelled: Bool { state.withLock { $0.cancelled } }
  private var reachedLimit: Bool { state.withLock { $0.total >= ProjectSearchResults.limit } }

  private func searchDocuments() {
    for document in documents {
      let room = ProjectSearchResults.limit - state.withLock { $0.total }
      guard room > 0,
        let found = LineMatches.search(
          document.text, query.regex, limit: room, isCancelled: { [self] in isCancelled })
      else { return }
      deposit(
        SearchFileMatches(
          path: document.path, matches: found.matches,
          document: .init(ranges: found.ranges, version: document.version)))
      state.withLock { $0.total += found.matches.count }
    }
  }

  /// git の出力の塊。行ごとに一致を取り、パスが変われば読みかけのまとまりを渡す。
  private func receive(_ data: Data, skipping skipped: Set<String>) {
    let lines = state.withLock { $0.cancelled || $0.stoppedAtLimit ? [] : $0.parser.feed(data) }
    for line in lines where !skipped.contains(line.path) {
      let room = state.withLock { ProjectSearchResults.limit - $0.total }
      guard room > 0 else { break }
      guard
        let matches = LineMatches.matches(
          of: query.regex, inLine: line.text as NSString, row: line.number - 1, limit: room,
          isCancelled: { [self] in isCancelled })
      else { return }
      guard !matches.isEmpty else { continue }
      let finished = state.withLock { state -> (path: String, matches: [SearchMatch])? in
        state.total += matches.count
        if state.current?.path == line.path {
          state.current?.matches += matches
          return nil
        }
        defer { state.current = (line.path, matches) }
        return state.current
      }
      if let finished { deposit(SearchFileMatches(path: finished.path, matches: finished.matches)) }
    }
    if reachedLimit {
      state.withLock { $0.stoppedAtLimit = true }
      stream.withLock { $0 }?.cancel()
    }
  }

  private func flushCurrent() {
    let current = state.withLock { state -> (path: String, matches: [SearchMatch])? in
      defer { state.current = nil }
      return state.current
    }
    if let current { deposit(SearchFileMatches(path: current.path, matches: current.matches)) }
  }

  /// まとまりを溜め、80ms 後に main へ渡す予約を 1 つだけ置く。一致 0 のまとまり（一致の無い開いている文書）は予約せず、
  /// 次か終わりの届けに乗せる——それだけの届けで前の結果を差し替えると、打つたびに列が空になる。
  private func deposit(_ file: SearchFileMatches) {
    let schedule = state.withLock { state -> Bool in
      guard !state.cancelled else { return false }
      let index = ProjectSearchResults.position(
        of: file.pathKey, in: state.pending.files, from: 0)
      state.pending.files.insert(file, at: index)
      guard file.count > 0, !state.flushScheduled else { return false }
      state.flushScheduled = true
      return true
    }
    guard schedule else { return }
    DispatchQueue.main.asyncAfter(deadline: .now() + Self.batchInterval) { [self] in
      flush(finished: false, error: nil)
    }
  }

  private func finish(error: GitGrep.Failure?) {
    DispatchQueue.main.async { [self] in flush(finished: true, error: error) }
  }

  private func flush(finished: Bool, error: GitGrep.Failure?) {
    let batch = state.withLock { state -> Batch? in
      guard !state.cancelled else { return nil }
      var batch = state.pending
      state.pending = Batch()
      state.flushScheduled = false
      batch.finished = finished
      batch.error = error
      return batch.files.isEmpty && !finished ? nil : batch
    }
    guard let batch else { return }
    MainActor.assumeIsolated { deliver(batch) }
  }
}
