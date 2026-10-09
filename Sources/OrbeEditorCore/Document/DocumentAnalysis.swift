import Foundation
import os

/// 本文の写しから裏で作る区間の列の問い。結果は問いと版つきで届き、問いが今と違う結果は捨てる。
public enum AnalysisRequest: Equatable, Sendable {
  /// ファイル内検索（`TextSearch.matches`）。
  case find(String)
  /// 選択文字列の出現（`Occurrences.selectionOccurrences`）——選択の列から決めた問いと、除く選択の列。
  case selectionOccurrences(
    SearchQuestion, selections: [NSRange], findNeedle: String?, findFieldFocused: Bool)
  /// キャレットの語の出現（`Occurrences.wordOccurrences`）。
  case wordOccurrences(NSRange)

  /// 問いの種類。種類ごとに新しい問いが古い問いを置き換える。
  public enum Kind: Hashable, Sendable {
    case find
    case selectionOccurrences
    case wordOccurrences
  }

  public var kind: Kind {
    switch self {
    case .find: .find
    case .selectionOccurrences: .selectionOccurrences
    case .wordOccurrences: .wordOccurrences
    }
  }
}

/// 裏の結果の受け取り箱。裏の仕事は結果を置いて main を起こし、main は起こされたとき（と、結果を同期で待つとき）に
/// 箱から取る。main を起こすだけ（`DispatchQueue.main.async` で結果を押し込まない）なのは、main が同期で待っている間にも
/// 結果を取れるようにするため——初めて見せるときの上限待ちと、追いつくのを待つ口がこの箱を読む。
final class AnalysisInbox: Sendable {
  struct Contents: Sendable {
    var syntax: [SyntaxOutcome] = []
    var comparison: ComparisonOutcome?
    var hunks: HunksOutcome?
    var ranges: [AnalysisRequest.Kind: RangesOutcome] = [:]
  }

  private struct State: Sendable {
    var contents = Contents()
    var wake: (@MainActor @Sendable () -> Void)?
    var wakeScheduled = false
  }

  private let state = OSAllocatedUnfairLock(initialState: State())
  private let arrived = DispatchSemaphore(value: 0)

  /// 結果が置かれたときに main で呼ぶもの（置かれるたびではなく、取られるまでに 1 回）。
  func setWake(_ wake: @escaping @MainActor @Sendable () -> Void) {
    state.withLock { $0.wake = wake }
  }

  func deposit(_ put: @Sendable (inout Contents) -> Void) {
    let wake = state.withLock { state -> (@MainActor @Sendable () -> Void)? in
      put(&state.contents)
      guard !state.wakeScheduled, let wake = state.wake else { return nil }
      state.wakeScheduled = true
      return wake
    }
    arrived.signal()
    if let wake { DispatchQueue.main.async { MainActor.assumeIsolated { wake() } } }
  }

  func take() -> Contents {
    state.withLock { state in
      defer {
        state.contents = Contents()
        state.wakeScheduled = false
      }
      return state.contents
    }
  }

  /// 次に結果が置かれるまで（`deadline` まで）待つ。置かれたら true。
  func wait(until deadline: DispatchTime) -> Bool {
    arrived.wait(timeout: deadline) == .success
  }
}

/// 本文と保存時の本文が同じかの結果。
struct ComparisonOutcome: Sendable {
  let version: Int
  let same: Bool
}

/// 行差分の結果。
struct HunksOutcome: Sendable {
  let version: Int
  /// どの baseline と上限に対する差分か（baseline か上限を置き直すたびに進む番号）。
  let generation: Int
  let hunks: [LineHunk]
}

/// 区間の列の問いの結果。
struct RangesOutcome: Sendable {
  let version: Int
  let request: AnalysisRequest
  let ranges: [NSRange]
}

/// 文書 1 つの、保存時の本文との比較・行差分・検索・出現の裏の仕事。写しと問いを受け取り、規則（純関数）を写しに対して
/// 回して、結果を版と問いつきで受け取り箱へ置く。種類ごとに最新の依頼だけを持ち（古い依頼の結果は要らない）、比較を
/// 最初に（違いの所で打ち切れて、届くまで未保存に見える）、出現を検索・行差分より先に片付ける。本文の写しは依頼ごとに
/// 読み、何も覚えない（検索と出現は窓ごとに読み、行差分は取る間だけ連続した列に写す）。
actor DocumentAnalysis {
  private enum Work: Sendable {
    case comparison(synced: TextRope)
    case hunks(baseline: String, limit: Int, generation: Int)
    case ranges(AnalysisRequest)
  }

  private struct Job: Sendable {
    let text: TextRope
    let version: Int
    let work: Work
  }

  private struct Mail: Sendable {
    var comparison: Job?
    var hunks: Job?
    var ranges: [AnalysisRequest.Kind: Job] = [:]
    var running = false

    /// 次に片付ける依頼（比較・語の出現・選択文字列の出現・検索・行差分の順）。
    mutating func next() -> Job? {
      if let job = comparison {
        comparison = nil
        return job
      }
      for kind in [AnalysisRequest.Kind.wordOccurrences, .selectionOccurrences, .find] {
        if let job = ranges.removeValue(forKey: kind) { return job }
      }
      defer { hunks = nil }
      return hunks
    }
  }

  private let queue = DispatchSerialQueue(label: "dev.orbe.editor.analysis")
  nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }
  private let mailbox = OSAllocatedUnfairLock(initialState: Mail())
  private let inbox: AnalysisInbox

  init(inbox: AnalysisInbox) {
    self.inbox = inbox
  }

  /// 本文と保存時の本文が同じかを頼む（main）。
  nonisolated func postComparison(text: TextRope, version: Int, synced: TextRope) {
    post { $0.comparison = Job(text: text, version: version, work: .comparison(synced: synced)) }
  }

  /// 行差分を頼む（main）。
  nonisolated func postHunks(
    text: TextRope, version: Int, baseline: String, limit: Int, generation: Int
  ) {
    post {
      $0.hunks = Job(
        text: text, version: version,
        work: .hunks(baseline: baseline, limit: limit, generation: generation))
    }
  }

  /// 区間の列の問いを頼む（main）。
  nonisolated func post(_ request: AnalysisRequest, text: TextRope, version: Int) {
    post { $0.ranges[request.kind] = Job(text: text, version: version, work: .ranges(request)) }
  }

  private nonisolated func post(_ put: @Sendable (inout Mail) -> Void) {
    let wake = mailbox.withLock { mail in
      put(&mail)
      defer { mail.running = true }
      return !mail.running
    }
    if wake { Task.detached(priority: .userInitiated) { [self] in await run() } }
  }

  private func run() {
    while let job = mailbox.withLock({ mail -> Job? in
      guard let job = mail.next() else {
        mail.running = false
        return nil
      }
      return job
    }) {
      switch job.work {
      case .comparison(let synced):
        let outcome = ComparisonOutcome(
          version: job.version, same: job.text.hasSameContent(as: synced))
        inbox.deposit { $0.comparison = outcome }
      case .hunks(let baseline, let limit, let generation):
        let hunks = LineDiff.hunks(base: baseline, current: job.text, limit: limit)
        let outcome = HunksOutcome(version: job.version, generation: generation, hunks: hunks)
        inbox.deposit { $0.hunks = outcome }
      case .ranges(let request):
        let outcome = RangesOutcome(
          version: job.version, request: request, ranges: ranges(of: request, in: job.text)
        )
        inbox.deposit { $0.ranges[request.kind] = outcome }
      }
    }
  }

  private func ranges(of request: AnalysisRequest, in text: TextRope) -> [NSRange] {
    switch request {
    case .find(let needle):
      TextSearch.matches(of: needle, in: text)
    case .selectionOccurrences(let question, let selections, let findNeedle, let findFieldFocused):
      Occurrences.selectionOccurrences(
        of: question, selections: selections, in: text, findNeedle: findNeedle,
        findFieldFocused: findFieldFocused)
    case .wordOccurrences(let word):
      Occurrences.wordOccurrences(of: word, in: text)
    }
  }
}
