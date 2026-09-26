import Foundation
import os
@preconcurrency import SwiftTreeSitter

/// 文書 1 つの構文の裏の仕事。構文木（`SyntaxLayer`）を状態に持ち、本文の写しから文書全体の役割の並びを作って受け取り箱
/// へ置く。専用の直列キューを executor にする——構文木は actor の中だけにあり、main からの参照はコンパイラが拒む。
///
/// 文書は編集ごとに、編集（行と桁つき）と最新の写しを郵便受けに積み、止まっていれば起こす。起きた裏の仕事は、郵便受けの
/// 編集をまとめて受け取って全部当ててから 1 回だけ差分解析し（速い打鍵は 1 回に畳まれる）、「構文木が変わった区間 ∪
/// 編集の区間」に掛かる行を丸ごと「まだ作り直していない」に足す——字の中身で役割が決まる capture（`#match?` など）は、
/// 構文木が変わらなくても役割が変わるから。作り直しは見えている範囲を先に、残りを一定量ずつ進め、区切りごとに役割の並びの
/// 写しと変わった区間を版つきで置く。区切りの間に新しい編集が来ていれば、それを先に当てる。
actor SyntaxWorker {
  /// 見えている範囲の外を 1 回に作り直す量（UTF-16）。区切りの間隔が、打鍵の再解析を待たせる上限になる。
  static let step = 16_384
  /// 見えている範囲を知らせる前（面を初めて見せる前）に先に作る行の数（高い画面の 1 画面ぶん）。
  static let initialVisibleLines = 120

  private struct Mail: Sendable {
    var text: TextRope
    var version: Int
    var edits: [VersionedEdit] = []
    var visible: NSRange
    var running = false
  }

  private let queue = DispatchSerialQueue(label: "dev.orbe.editor.syntax")
  nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }
  private let mailbox: OSAllocatedUnfairLock<Mail>
  private let inbox: AnalysisInbox
  private let layer: SyntaxLayer
  private var text: TextRope
  private var version: Int
  private var roles: RoleRuns
  /// まだ作り直していない範囲（`text` の上）。
  private var stale = IndexSet()
  /// 前に置いてから作り直した範囲（`text` の上）。
  private var changed = IndexSet()
  private var parsed = false

  init(
    text: TextRope, version: Int, configuration: LanguageConfiguration, registry: LanguageRegistry,
    inbox: AnalysisInbox
  ) throws {
    layer = try SyntaxLayer(configuration: configuration, registry: registry)
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
      defer { mail.running = true }
      return !mail.running
    }
    if wake { Task.detached(priority: .userInitiated) { [self] in await run() } }
  }

  /// 見えている範囲（最新の版のオフセット）。次の区切りから、そこを先に作る。
  nonisolated func setVisible(_ range: NSRange) {
    mailbox.withLock { $0.visible = range }
  }

  /// main が結果を同期で待つ間、キューの優先度を上げる（待っている main は優先度を譲らない）。
  nonisolated func boost() {
    queue.async(qos: .userInteractive, flags: .enforceQoS) {}
  }

  private func run() {
    while true {
      let idle = parsed && stale.isEmpty
      let batch = mailbox.withLock { mail -> Mail? in
        guard !mail.edits.isEmpty || !idle else {
          mail.running = false
          return nil
        }
        defer { mail.edits = [] }
        return mail
      }
      guard let batch else { return }
      absorb(batch)
      if !stale.isEmpty { rebuild(visible: batch.visible) }
    }
  }

  /// 郵便受けの編集を当てて再解析し、作り直す範囲を足す。初めてなら最新の写しを丸ごと解析する。
  private func absorb(_ batch: Mail) {
    text = batch.text
    guard parsed else {
      version = batch.version
      layer.parseAll(text)
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
    for range in layer.didChange(batch.edits, text: text).rangeView {
      let covered = lines(covering: NSRange(range))
      stale.insert(integersIn: covered.location..<NSMaxRange(covered))
    }
  }

  /// 作り直していない範囲を 1 区切りぶん作り直して置く。見えている行に掛かる部分が先。
  private func rebuild(visible: NSRange) {
    let shown = lines(covering: visible)
    let target: NSRange
    if let part = stale.intersection(IndexSet(integersIn: shown.location..<NSMaxRange(shown)))
      .rangeView.first
    {
      target = NSRange(part)
    } else {
      let part = stale.rangeView.first!
      target = NSRange(location: part.lowerBound, length: min(part.count, Self.step))
    }
    roles.replace(target, with: layer.roles(in: target, text: text))
    stale.remove(integersIn: target.location..<NSMaxRange(target))
    changed.insert(integersIn: target.location..<NSMaxRange(target))
    let outcome = SyntaxOutcome(
      version: version, roles: roles, changed: changed,
      visibleReady: !stale.intersects(integersIn: shown.location..<NSMaxRange(shown)),
      complete: stale.isEmpty)
    changed = IndexSet()
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
  /// 前の区切りから作り直した範囲（`version` の本文の上）。
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
