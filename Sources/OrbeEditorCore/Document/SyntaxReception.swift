import Foundation

/// 構文の裏の仕事と、その結果の受け取り——文書（`EditorDocument`）とリビジョンの文書（`RevisionDocument`）が共有する。裏の
/// 仕事を起こし、受け取り箱に届いた結果の役割を今の版へ写して置き、見えている範囲を裏へ渡し、初めて見せるときの色の上限
/// 待ちを行う。受け取り箱は持ち主のもので、持ち主が箱から取った結果のうち構文のものをここへ渡す。
struct SyntaxReception {
  /// 初めて画面に出すとき、最初の色を待つ上限。
  static let firstColorsWait: TimeInterval = 0.05

  private(set) var worker: SyntaxWorker?
  /// 最後に受け取った結果の版と、そのとき見えている範囲・全体の作り直しが済んでいたか。
  private var progress = SyntaxProgress(version: 0, visibleReady: false, complete: false)
  private(set) var hasBeenShown = false

  /// 言語の規則があれば裏の仕事を起こし、全体の解析と先頭の画面ぶんの役割を作り始める（待たない）。
  init(
    text: TextRope, version: Int, language: SyntaxLanguage?, registry: LanguageRegistry,
    inbox: AnalysisInbox, quietDelay: DispatchTimeInterval
  ) {
    worker = language.flatMap { registry.rules(for: $0) }.map {
      SyntaxWorker(
        text: text, version: version, rules: $0, registry: registry, inbox: inbox,
        quietDelay: quietDelay)
    }
  }

  /// 最後に受け取った結果の版（裏の仕事が無ければ nil）。これより後ろの版の結果が届きうる。
  var receivedVersion: Int? { worker == nil ? nil : progress.version }

  /// 版 `version` の見えている範囲の色が揃っている（裏の仕事が無ければいつも）。
  func isFirstColorReady(at version: Int) -> Bool {
    worker == nil || (progress.version == version && progress.visibleReady)
  }

  /// 版 `version` の全体の色が揃っている（裏の仕事が無ければいつも）。
  func isComplete(at version: Int) -> Bool {
    worker == nil || (progress.version == version && progress.complete)
  }

  /// 届いた結果の役割を今の版へ写して `roles` に置き、役割の変わった区間（今の座標）を返す。`edits` は版から今までの編集
  /// （写せない古い版なら nil）。
  mutating func receive(
    _ outcomes: [SyntaxOutcome], roles: inout RoleRuns,
    edits: (Int) -> ArraySlice<VersionedEdit>?
  ) -> IndexSet {
    var changedRoles = IndexSet()
    for outcome in outcomes {
      guard let applied = edits(outcome.version) else { continue }
      changedRoles.formUnion(
        EditSweep.batches(applied: applied.map(\.edit)).reduce(outcome.changed) { $1.track($0) })
    }
    if let outcome = outcomes.last, let applied = edits(outcome.version) {
      var latest = outcome.roles
      for record in applied { latest.apply(record.edit) }
      roles = latest
      progress = SyntaxProgress(
        version: outcome.version, visibleReady: outcome.visibleReady, complete: outcome.complete)
    }
    return changedRoles
  }

  /// 見えている行 `lines`（`text` の行）を裏へ渡す。次の区切りから、そこを先に作る。
  func setVisible(_ lines: ClosedRange<Int>, in text: TextRope) {
    guard let worker else { return }
    let first = min(lines.lowerBound, text.lineCount - 1)
    let last = min(lines.upperBound, text.lineCount - 1)
    worker.setVisible(
      NSRange(location: text.lineStart(first), length: text.lineEnd(last) - text.lineStart(first)))
  }

  /// 面の見えている範囲 `viewport` に掛かる行（`text` の行）。
  static func lines(of viewport: TextViewport, in text: TextRope) -> ClosedRange<Int> {
    let first = text.row(containing: viewport.firstVisible)
    return first...(first + Int(viewport.visibleLines.rounded(.up)))
  }

  /// 初めて画面に出す直前に呼ぶ。初めてで、見えている範囲の色が揃っていなければ（`ready` が偽）、裏の仕事の優先度を上げて
  /// true を返す——持ち主は最大 `firstColorsWait` 待つ（越えたら無色で出し、後から色が付く）。
  mutating func beginShowing(ready: Bool) -> Bool {
    guard !hasBeenShown else { return false }
    hasBeenShown = true
    guard let worker, !ready else { return false }
    worker.boost()
    return true
  }

  /// 裏の仕事を手放す（持ち主を閉じたとき、裏で手放す部品へ移す）。走っている解析を打ち切らせる。
  mutating func release() -> SyntaxWorker? {
    defer { worker = nil }
    worker?.cancel()
    return worker
  }

  /// 追いつくのを同期で待つ間（`body`）だけ、`worker` に見えていない範囲も待たずに作らせ、キューの優先度を上げる。
  static func hurrying(_ worker: SyntaxWorker?, _ body: () -> Bool) -> Bool {
    worker?.setHurry(true)
    defer { worker?.setHurry(false) }
    worker?.boost()
    return body()
  }

  /// 受け取り箱 `inbox` に結果が届くたびに `receive` で受け取り、`done` が成り立つか期限が来るまで待つ。
  static func wait(
    on inbox: AnalysisInbox, until deadline: DispatchTime, receive: () -> Void,
    _ done: () -> Bool
  ) -> Bool {
    receive()
    while !done() {
      guard inbox.wait(until: deadline) else { break }
      receive()
    }
    return done()
  }
}
