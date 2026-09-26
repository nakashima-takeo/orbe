import Foundation
import os

/// 本文の写しから裏で作る区間の列の問い。結果は問いと版つきで届き、問いが今と違う結果は捨てる。
public enum AnalysisRequest: Equatable, Sendable {
  /// ファイル内検索（`TextSearch.matches`）。
  case find(String)
  /// 選択文字列の出現（`Occurrences.selectionOccurrences`）。
  case selectionOccurrences(selection: NSRange, findNeedle: String?, findFieldFocused: Bool)
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

/// 行差分の結果。
struct HunksOutcome: Sendable {
  let version: Int
  /// どの baseline に対する差分か（baseline を置き直すたびに進む番号）。
  let generation: Int
  let hunks: [LineHunk]
}

/// 区間の列の問いの結果。
struct RangesOutcome: Sendable {
  let version: Int
  let request: AnalysisRequest
  let ranges: [NSRange]
}

/// 文書 1 つの、行差分・検索・出現の裏の仕事。写しと問いを受け取り、規則（純関数）を写しに対して回して、結果を版と問い
/// つきで受け取り箱へ置く。種類ごとに最新の依頼だけを持ち（古い依頼の結果は要らない）、キャレットに近い出現から先に
/// 片付ける。写しは連続した UTF-16 の列に写してから探す（大小無視の一致の意味を今のまま保つ。main には載らない）。
actor DocumentAnalysis {
  private enum Work: Sendable {
    case hunks(baseline: String, generation: Int)
    case ranges(AnalysisRequest)
  }

  private struct Job: Sendable {
    let text: TextRope
    let version: Int
    let work: Work
  }

  private struct Mail: Sendable {
    var hunks: Job?
    var ranges: [AnalysisRequest.Kind: Job] = [:]
    var running = false

    /// 次に片付ける依頼（語の出現・選択文字列の出現・検索・行差分の順）。
    mutating func next() -> Job? {
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
  /// 最後に写した版の連続した本文（検索・出現は NSString、行差分は String で読む）。
  private var flattened: (version: Int, units: ContiguousArray<UInt16>)?
  private var nsString: (version: Int, value: NSString)?
  private var string: (version: Int, value: String)?

  init(inbox: AnalysisInbox) {
    self.inbox = inbox
  }

  /// 行差分を頼む（main）。
  nonisolated func postHunks(text: TextRope, version: Int, baseline: String, generation: Int) {
    post {
      $0.hunks = Job(
        text: text, version: version, work: .hunks(baseline: baseline, generation: generation))
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
      case .hunks(let baseline, let generation):
        let hunks = LineDiff.hunks(base: baseline, current: string(of: job))
        let outcome = HunksOutcome(version: job.version, generation: generation, hunks: hunks)
        inbox.deposit { $0.hunks = outcome }
      case .ranges(let request):
        let outcome = RangesOutcome(
          version: job.version, request: request, ranges: ranges(of: request, in: nsString(of: job))
        )
        inbox.deposit { $0.ranges[request.kind] = outcome }
      }
    }
  }

  private func ranges(of request: AnalysisRequest, in text: NSString) -> [NSRange] {
    switch request {
    case .find(let needle):
      TextSearch.matches(of: needle, in: text as String)
    case .selectionOccurrences(let selection, let findNeedle, let findFieldFocused):
      Occurrences.selectionOccurrences(
        of: selection, in: text as String, findNeedle: findNeedle,
        findFieldFocused: findFieldFocused)
    case .wordOccurrences(let word):
      Occurrences.wordOccurrences(of: word, in: text as String)
    }
  }

  private func units(of job: Job) -> ContiguousArray<UInt16> {
    if let flattened, flattened.version == job.version { return flattened.units }
    let units = job.text.contiguousUnits()
    flattened = (job.version, units)
    return units
  }

  private func nsString(of job: Job) -> NSString {
    if let nsString, nsString.version == job.version { return nsString.value }
    let value = units(of: job).withUnsafeBufferPointer { buffer in
      buffer.baseAddress.map { NSString(characters: $0, length: buffer.count) } ?? ""
    }
    nsString = (job.version, value)
    return value
  }

  private func string(of job: Job) -> String {
    if let string, string.version == job.version { return string.value }
    let value = String(decoding: units(of: job), as: UTF16.self)
    string = (job.version, value)
    return value
  }
}
