import Foundation
import os

/// 文書のアウトラインの状態。結果は取り出した版のまま持ち（打鍵のたびにシンボルの位置をずらさない）、位置の問いは文書が
/// 問いと答えを結果の版と今の版の間で写して答える。
struct OutlineState {
  /// 入れ替えや閉じることで外れた結果と絞り込み。解放はシンボルの数に比例するので、main では手放さず裏へ渡す。
  struct Retired: Sendable {
    var outlines: [DocumentOutline] = []
    var filters: [OutlineFilterResult] = []

    var isEmpty: Bool { outlines.isEmpty && filters.isEmpty }
  }

  /// 閉じた文書から裏で手放すもの。
  struct Parts: Sendable {
    let worker: OutlineWorker?
    let retired: Retired
  }

  /// アウトラインの裏の仕事（文法とアウトラインの規則がある言語だけ。閉じたら外す）。
  private(set) var worker: OutlineWorker?
  var wanted = false
  var shown: DocumentOutline? {
    didSet { if let oldValue { retired.outlines.append(oldValue) } }
  }
  var filter: OutlineFilterResult? {
    didSet { if let oldValue { retired.filters.append(oldValue) } }
  }
  /// 届いたが、今の文字列の絞り込みが揃うまで見せていない結果。
  var staged: DocumentOutline? {
    didSet { if let oldValue { retired.outlines.append(oldValue) } }
  }
  /// 絞り込みの文字列（空なら絞り込まない）。
  var pattern = ""
  /// 結果を待ち始めた版（それより後の版の結果は、届くまで写せるように記録を持つ）。
  var awaited = 0
  private var retired = Retired()

  init(rules: GrammarRules?, inbox: AnalysisInbox) {
    worker = rules.flatMap { rules in
      rules.outline.map { OutlineWorker(query: $0, grammar: rules.grammar, inbox: inbox) }
    }
  }

  /// 記録を持っておく最も古い版（要らなければ nil）。
  var oldestAwaited: Int? {
    guard wanted, worker != nil else { return nil }
    return min(shown?.version ?? awaited, staged?.version ?? .max)
  }

  /// 要るなら、結果が今の版に追いつき、今の文字列の絞り込みが揃っている。
  func isCaughtUp(version: Int) -> Bool {
    guard wanted, worker != nil else { return true }
    guard let shown, shown.version == version, staged == nil else { return false }
    return pattern.isEmpty
      ? filter == nil : filter?.pattern == pattern && filter?.token == shown.token
  }

  /// 外れたものを取り出す（持ち主が裏へ渡す）。
  mutating func takeRetired() -> Retired {
    defer { retired = Retired() }
    return retired
  }

  /// 閉じる。取り出しを打ち切り、大きな部品を外して返す。
  mutating func release() -> Parts {
    worker?.cancel()
    shown = nil
    staged = nil
    filter = nil
    defer { worker = nil }
    return Parts(worker: worker, retired: takeRetired())
  }
}

/// アウトライン——要るかの切り替え・結果と絞り込みの受け取り・位置の問い。位置の問いは、問いの位置を結果の版へ戻し、
/// 答えの区間を今の版へ進める（どちらも結果の版から後ろの編集の数にだけ比例する）。
extension EditorDocument {
  /// アウトラインが要る（Orbe が告げる）。要る間は、打鍵が止むたびに取り直し、結果の版から後ろの編集の記録を持つ。
  /// 要るようになった時点で今の本文へ写せない結果は捨て（届くまで `outline` は nil）、編集していなければ取り直さない。
  public var wantsOutline: Bool {
    get { outlineState.wanted }
    set {
      guard newValue != outlineState.wanted else { return }
      outlineState.wanted = newValue
      syntax?.setOutlineWanted(newValue && supportsOutline)
      guard newValue, supportsOutline else { return }
      outlineState.awaited = version
      guard let shown = outline, log.edits(since: shown.version) == nil else { return }
      outlineState.shown = nil
      outlineState.filter = nil
      outlineState.staged = nil
      outlineDidChange(notify: true)
    }
  }

  /// 言語がアウトラインを出せる（文法とアウトラインの規則がある）。
  public var supportsOutline: Bool { outlineState.worker != nil }

  /// 見せているアウトライン（取り直しの間は前の結果）。
  public var outline: DocumentOutline? { outlineState.shown }

  /// `outline` の絞り込み（絞り込んでいなければ nil）。結果と絞り込みは揃えて入れ替わる。
  public var outlineFilter: OutlineFilterResult? { outlineState.filter }

  /// 絞り込みの文字列を置く（空なら絞り込まない）。照合は裏で行い、揃ったら `onOutlineChange` が来る。それまでは前の
  /// 絞り込みを見せ続ける。
  public func filterOutline(_ pattern: String) {
    guard pattern != outlineState.pattern else { return }
    outlineState.pattern = pattern
    outlineState.worker?.setPattern(pattern)
    guard pattern.isEmpty, outlineState.filter != nil || outlineState.staged != nil else { return }
    if let staged = outlineState.staged { outlineState.shown = staged }
    outlineState.staged = nil
    outlineState.filter = nil
    outlineDidChange(notify: true)
  }

  /// 今の本文の `offset` を含む最も深いシンボルの番号。`token` が見せている結果と違えば nil。
  public func outlineSymbol(containing offset: Int, in token: OutlineToken) -> Int? {
    guard let outline, outline.token == token,
      let offset = log.unmap(offset, to: outline.version)
    else { return nil }
    return outline.deepest(containing: offset)
  }

  /// シンボルの名前の今の区間（飛び先）。編集で名前が消えていれば、範囲の頭（長さ 0）。
  public func outlineNameRange(of index: Int, in token: OutlineToken) -> NSRange? {
    guard let outline, outline.token == token, outline.symbols.indices.contains(index) else {
      return nil
    }
    let name = outline.nameRanges[index]
    if let current = currentRange(name, from: outline.version),
      current.length > 0 || name.length == 0
    {
      return current
    }
    return log.map(outline.ranges[index].location, from: outline.version, bias: .after).map {
      NSRange(location: $0, length: 0)
    }
  }

  /// シンボルの範囲の今の区間。
  public func outlineRange(of index: Int, in token: OutlineToken) -> NSRange? {
    guard let outline, outline.token == token, outline.symbols.indices.contains(index) else {
      return nil
    }
    return currentRange(outline.ranges[index], from: outline.version)
  }

  /// 結果の版の区間を今の版へ写す（頭は後ろへ、終わりは前へ寄せる。潰れたら頭で長さ 0）。
  private func currentRange(_ range: NSRange, from version: Int) -> NSRange? {
    guard let start = log.map(range.location, from: version, bias: .after),
      let end = log.map(NSMaxRange(range), from: version, bias: .before)
    else { return nil }
    return NSRange(location: start, length: max(0, end - start))
  }

  /// 受け取り箱のアウトラインの結果と絞り込みを置く。今の本文へ写せない結果は捨てる（写せる版の結果がまた届く）。
  /// 絞り込み中は、結果とその絞り込みが揃うまで新しい結果を見せない。
  func receiveOutline(_ contents: AnalysisInbox.Contents) {
    var changed = false
    let pattern = outlineState.pattern
    if let outcome = contents.outline, log.edits(since: outcome.outline.version) != nil {
      if pattern.isEmpty || outcome.filter?.pattern == pattern {
        outlineState.shown = outcome.outline
        outlineState.filter = pattern.isEmpty ? nil : outcome.filter
        outlineState.staged = nil
        changed = true
      } else {
        outlineState.staged = outcome.outline
      }
    }
    if let filter = contents.outlineFilter, !pattern.isEmpty, filter.pattern == pattern {
      if let staged = outlineState.staged, staged.token == filter.token {
        outlineState.shown = staged
        outlineState.staged = nil
        outlineState.filter = filter
        changed = true
      } else if outline?.token == filter.token {
        outlineState.filter = filter
        changed = true
      }
    }
    outlineDidChange(notify: changed)
  }

  /// 知らせてから、外れた結果と絞り込みを裏で手放す——pane は知らせの中で自分の写しを差し替えるので、知らせの後は
  /// ここが最後の参照になる。
  private func outlineDidChange(notify: Bool) {
    if notify { onOutlineChange?() }
    let retired = outlineState.takeRetired()
    guard !retired.isEmpty else { return }
    releaseOutlines(OSAllocatedUnfairLock(initialState: consume retired))
  }
}
