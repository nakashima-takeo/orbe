import Foundation
import os

/// 文書 1 つのアウトラインの裏の仕事（utility）。構文の裏の仕事が打鍵の止んだときに手放す根の構文木の写しから
/// アウトラインを取り出し、絞り込みの文字列が変われば最新の結果に照合をかけて、結果を受け取り箱へ置く。依頼は種類ごとに
/// 最新だけを持ち（`DocumentAnalysis` と同じ形）、新しい写しが届いたら走っている取り出しを問い合わせの途中で打ち切る。
/// 構文木の写しはここで読み、ここで手放す。
actor OutlineWorker {
  private struct Extraction: Sendable {
    let tree: TreeCopy
    let text: TextRope
    let version: Int
  }

  private struct Mail: Sendable {
    var extraction: Extraction?
    var pattern: String?
    var running = false
    /// 走っている取り出しの打ち切りの印。
    var current: SyntaxCancellation?
    var closed = false
  }

  private let queue = DispatchSerialQueue(label: "dev.orbe.editor.outline", qos: .utility)
  nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }
  private let mailbox = OSAllocatedUnfairLock(initialState: Mail())
  private let inbox: AnalysisInbox
  private let extraction: OutlineExtraction
  private var outline: DocumentOutline?
  private var pattern = ""
  private var filter: OutlineFilter?

  init(query: OutlineQuery, grammar: Grammar, inbox: AnalysisInbox) {
    extraction = OutlineExtraction(query: query, grammar: grammar)
    self.inbox = inbox
  }

  /// 取り出しを頼む（構文の裏の仕事から）。走っている取り出しは打ち切る。
  nonisolated func extract(_ tree: TreeCopy, text: TextRope, version: Int) {
    post { mail in
      mail.extraction = Extraction(tree: tree, text: text, version: version)
      mail.current?.cancel()
    }
  }

  /// 絞り込みの文字列が変わった（main）。空なら絞り込まない。
  nonisolated func setPattern(_ pattern: String) {
    post { $0.pattern = pattern }
  }

  /// 文書を閉じた。走っている取り出しを打ち切り、以後は何もしない。
  nonisolated func cancel() {
    mailbox.withLock { mail in
      mail.closed = true
      mail.current?.cancel()
    }
  }

  private nonisolated func post(_ put: @Sendable (inout Mail) -> Void) {
    let wake = mailbox.withLock { mail in
      put(&mail)
      guard !mail.running, !mail.closed else { return false }
      mail.running = true
      return true
    }
    if wake { Task.detached(priority: .utility) { [self] in await run() } }
  }

  /// 1 回ぶんの依頼（取り出しと、変わった絞り込みの文字列）と、その取り出しの打ち切りの印。
  private struct Batch {
    let extraction: Extraction?
    let pattern: String?
    let cancellation: SyntaxCancellation
  }

  /// 郵便受けの依頼を取る。無ければ（閉じていれば）止まった印を付けて nil。
  private nonisolated func take() -> Batch? {
    mailbox.withLock { mail in
      guard !mail.closed, mail.extraction != nil || mail.pattern != nil else {
        mail.running = false
        mail.current = nil
        return nil
      }
      defer {
        mail.extraction = nil
        mail.pattern = nil
      }
      let cancellation = SyntaxCancellation()
      mail.current = cancellation
      return Batch(
        extraction: mail.extraction, pattern: mail.pattern, cancellation: cancellation)
    }
  }

  private func run() {
    while let batch = take() {
      if let pattern = batch.pattern { self.pattern = pattern }
      var extracted: DocumentOutline?
      if let job = batch.extraction {
        guard
          let outline = extraction.run(
            job.tree.tree, text: job.text, version: job.version,
            cancellation: batch.cancellation)
        else { continue }
        extracted = outline
        self.outline = outline
        filter = nil
      }
      guard let outline else { continue }
      let filtered = filtered(outline)
      if let extracted {
        inbox.deposit { $0.outline = OutlineOutcome(outline: extracted, filter: filtered) }
      } else if batch.pattern != nil {
        inbox.deposit { $0.outlineFilter = filtered }
      }
    }
  }

  /// 今の文字列で最新の結果を絞り込む（空なら nil）。
  private func filtered(_ outline: DocumentOutline) -> OutlineFilterResult? {
    guard !pattern.isEmpty else { return nil }
    if filter?.token != outline.token { filter = OutlineFilter(outline) }
    return filter?.apply(pattern)
  }
}

/// アウトラインの取り出しの結果。絞り込み中なら、同じ結果の絞り込みを添える（main が結果と絞り込みを揃えて入れ替える）。
struct OutlineOutcome: Sendable {
  let outline: DocumentOutline
  let filter: OutlineFilterResult?
}
