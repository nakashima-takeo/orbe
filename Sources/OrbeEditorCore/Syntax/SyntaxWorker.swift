import Foundation
import os

/// 文書 1 つの構文の裏の仕事。構文の層（`SyntaxLayers`）を状態に持ち、本文の写しから文書全体の役割の並びを作って受け取り箱
/// へ置く。専用の直列キューを executor にする——構文木は actor の中だけにあり、main からの参照はコンパイラが拒む。
///
/// 文書は編集ごとに、編集（行と桁つき）と最新の写しを郵便受けに積み、止まっていれば起こす。起きた裏の仕事は、郵便受けの
/// 編集をまとめて受け取って全部当ててから 1 回だけ差分解析し（速い打鍵は 1 回に畳まれる）、「構文木が変わった区間 ∪
/// 編集の区間」に掛かる行を丸ごと「まだ作り直していない」に足す——字の中身で役割が決まる capture（`#match?` など）は、
/// 構文木が変わらなくても役割が変わるから。作り直しは区画ずつ、見えている範囲を先に進め、区切りごとに役割の並びの写しと役割が
/// 変わった字を版つきで置く。見えていない範囲は、最後の編集から `quietDelay` 経つまで始めない（打鍵が続く間は見えている範囲
/// だけを作る。開いてから編集が無ければ待たない）。区切りの間に新しい編集が来ていれば、それを先に当てる。文書を閉じたら、走っている解析を打ち切って止まる。
actor SyntaxWorker {
  /// 見えている範囲を知らせる前（面を初めて見せる前）に先に作る行の数（高い画面の 1 画面ぶん）。
  static let initialVisibleLines = 120
  /// 最後の編集から、見えていない範囲の作り直しを始めるまでの待ち（既定）。
  static let quietDelay: DispatchTimeInterval = .milliseconds(250)

  private struct Mail: Sendable {
    var text: TextRope
    var version: Int
    var edits: [VersionedEdit] = []
    var visible: NSRange
    var running = false
    /// 見えていない範囲の作り直しを始めてよくなる時刻（最後の編集 ＋ 待ち）。編集がまだ無ければ nil（待たない）。
    var quietAt: DispatchTime?
    /// 見えていない範囲も待たずに作る（main が文書全体の結果を同期で待っている）。
    var hurry = false
    /// 止まったとき、作り直していない範囲が残っていた。
    var hasStale = false
    /// 待ちの明けに起こす予約がある。
    var timerPending = false
  }

  private let queue = DispatchSerialQueue(label: "dev.orbe.editor.syntax")
  nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }
  private let mailbox: OSAllocatedUnfairLock<Mail>
  private let inbox: AnalysisInbox
  private let cancellation = SyntaxCancellation()
  private let quietDelay: DispatchTimeInterval
  private let layers: SyntaxLayers
  private var text: TextRope
  private var version: Int
  private var roles: RoleRuns
  /// まだ作り直していない範囲（`text` の上）。
  private var stale = IndexSet()
  /// 前に置いてから役割が変わった字（`text` の上）。
  private var changed = IndexSet()
  /// 最後に結果を置いた版。
  private var deposited: Int?
  private var parsed = false

  init(
    text: TextRope, version: Int, rules: GrammarRules, registry: LanguageRegistry,
    inbox: AnalysisInbox, quietDelay: DispatchTimeInterval = SyntaxWorker.quietDelay
  ) {
    self.quietDelay = quietDelay
    layers = SyntaxLayers(rules: rules, registry: registry, cancellation: cancellation)
    self.text = text
    self.version = version
    self.inbox = inbox
    roles = RoleRuns(length: text.length)
    let visible = NSRange(location: 0, length: text.lineEnd(Self.initialVisibleLines - 1))
    mailbox = OSAllocatedUnfairLock(
      initialState: Mail(text: text, version: version, visible: visible, running: true))
    Task.detached(priority: .userInitiated) { [self] in await run() }
  }

  /// 編集を積む（main）。止まっていれば起こす。
  nonisolated func post(_ edit: VersionedEdit, text: TextRope) {
    let wake = mailbox.withLock { mail in
      mail.edits.append(edit)
      mail.text = text
      mail.version = edit.version
      mail.quietAt = .now() + quietDelay
      defer { mail.running = true }
      return !mail.running
    }
    if wake { start() }
  }

  /// 見えている範囲（最新の版のオフセット）。次の区切りから、そこを先に作る——待ちの間に止まっていても、そこは待たずに作る。
  nonisolated func setVisible(_ range: NSRange) {
    wakeIfStale { $0.visible = range }
  }

  /// main が結果を同期で待つ間、キューの優先度を上げる（待っている main は優先度を譲らない）。
  nonisolated func boost() {
    queue.async(qos: .userInteractive, flags: .enforceQoS) {}
  }

  /// true の間、見えていない範囲も待たずに作る。main が文書全体の結果を同期で待つ間だけ立てる。
  nonisolated func setHurry(_ hurry: Bool) {
    guard hurry else {
      mailbox.withLock { $0.hurry = false }
      return
    }
    wakeIfStale { $0.hurry = true }
  }

  /// 文書を閉じた。走っている解析を打ち切り、以後は何もしない。
  nonisolated func cancel() {
    cancellation.cancel()
  }

  private nonisolated func start() {
    Task.detached(priority: .userInitiated) { [self] in await run() }
  }

  /// 郵便受けを書き換え、作り直していない範囲を残して止まっていれば起こす。
  private nonisolated func wakeIfStale(_ change: @Sendable (inout Mail) -> Void) {
    let wake = mailbox.withLock { mail in
      change(&mail)
      guard !mail.running, mail.hasStale else { return false }
      mail.running = true
      return true
    }
    if wake { start() }
  }

  /// 待ちの明け。
  private nonisolated func quietElapsed() {
    wakeIfStale { $0.timerPending = false }
  }

  private func run() {
    while !cancellation.isCancelled {
      let batch = mailbox.withLock { mail -> Mail in
        defer { mail.edits = [] }
        return mail
      }
      absorb(batch)
      guard !layers.isCancelled else { return }
      let shown = lines(covering: batch.visible)
      let quiet = batch.hurry || batch.quietAt.map { DispatchTime.now() >= $0 } ?? true
      if let target = nextTarget(shown: shown, quiet: quiet) {
        rebuild(target, shown: shown)
        continue
      }
      if deposited != version { deposit(visibleReady: true) }
      let hasStale = !stale.isEmpty
      let wait = mailbox.withLock { mail -> DispatchTime?? in
        guard mail.edits.isEmpty, mail.visible == batch.visible, mail.hurry == batch.hurry else {
          return nil
        }
        mail.running = false
        mail.hasStale = hasStale
        guard hasStale, !mail.timerPending, let quietAt = mail.quietAt else { return .some(nil) }
        mail.timerPending = true
        return .some(quietAt)
      }
      guard let wait else { continue }
      if let deadline = wait {
        let wake: @Sendable () -> Void = { [weak self] in self?.quietElapsed() }
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: deadline, execute: wake)
      }
      return
    }
  }

  /// 郵便受けの編集を当てて再解析し、作り直す範囲を足す。初めてなら最新の写しを丸ごと解析する。
  private func absorb(_ batch: Mail) {
    text = batch.text
    guard parsed else {
      version = batch.version
      layers.parseAll(text)
      roles = RoleRuns(length: text.length)
      stale = IndexSet(integersIn: 0..<text.length)
      parsed = true
      return
    }
    guard !batch.edits.isEmpty else { return }
    for record in batch.edits {
      roles.apply(record.edit)
      stale = record.edit.track(stale)
      changed = record.edit.track(changed)
    }
    version = batch.version
    for range in layers.apply(batch.edits, text: text).rangeView {
      let covered = lines(covering: NSRange(range))
      stale.insert(integersIn: covered.location..<NSMaxRange(covered))
    }
    stale.formUnion(layers.takeInvalidated())
  }

  /// 次に作り直す区画。見えている行に掛かる部分が先。見えていない部分は待ちが明けてから。
  private func nextTarget(shown: NSRange, quiet: Bool) -> Range<Int>? {
    let part =
      stale.intersection(IndexSet(integersIn: shown.location..<NSMaxRange(shown))).rangeView.first
      ?? (quiet ? stale.rangeView.first : nil)
    guard let part else { return nil }
    let block = (part.lowerBound / SyntaxLayers.block + 1) * SyntaxLayers.block
    return part.lowerBound..<min(part.upperBound, block)
  }

  /// 区画 1 つを作り直して置く。
  private func rebuild(_ target: Range<Int>, shown: NSRange) {
    let spans = layers.roles(in: NSRange(target))
    guard !layers.isCancelled else { return }
    stale.formUnion(layers.takeInvalidated())
    changed.formUnion(roles.replace(NSRange(target), with: spans))
    stale.remove(integersIn: target)
    deposit(visibleReady: !stale.intersects(integersIn: shown.location..<NSMaxRange(shown)))
  }

  /// 今の版の役割の並びと、前に置いてから役割が変わった字を受け取り箱へ置く。取り込んだ版には必ず 1 つ置く（作り直す
  /// 範囲が空の版——空の本文や、編集で作り直す範囲が消えた版——でも、文書が追いついたと分かるように）。
  private func deposit(visibleReady: Bool) {
    let outcome = SyntaxOutcome(
      version: version, roles: roles, changed: changed, visibleReady: visibleReady,
      complete: stale.isEmpty)
    changed = IndexSet()
    deposited = version
    inbox.deposit { $0.syntax.append(outcome) }
  }

  /// 区間に掛かる行を丸ごと（改行を含む）。本文の外は切り詰める。
  private func lines(covering range: NSRange) -> NSRange {
    let start = min(range.location, text.length)
    let end = min(NSMaxRange(range), text.length)
    let first = text.lineStart(text.row(containing: start))
    let last = text.lineEnd(text.row(containing: max(start, end - 1)))
    return NSRange(location: first, length: max(0, last - first))
  }
}

/// 構文の裏の仕事の 1 区切りの結果。
struct SyntaxOutcome: Sendable {
  let version: Int
  let roles: RoleRuns
  /// 前の区切りから役割が変わった字（`version` の本文の上）。
  let changed: IndexSet
  /// 見えている範囲の作り直しが済んだ。
  let visibleReady: Bool
  /// 文書全体の作り直しが済んだ。
  let complete: Bool
}

/// 構文の裏の仕事がどこまで進んだか（文書が最後に受け取った結果の版で）。
struct SyntaxProgress {
  let version: Int
  let visibleReady: Bool
  let complete: Bool
}
