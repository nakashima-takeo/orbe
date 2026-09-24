import Foundation
import OrbeEditorCore

/// ファイル内検索の状態——needle・一致の列・結んだ文書。「現在の一致」は持たず、選択から導く——選択がちょうど一致の
/// どれかならそれ、そうでなければ無い（VS Code と同じく、本文をクリック・打鍵して選択が一致から外れれば現在の地は消え、
/// 件数の位置は「?」）。Enter・⇧Enter の行き先は Core の規則（`TextSearch.next` / `previous`）。選択の変化を観測して
/// 件数と現在の一致の地を導き直す。面への作用は契約（選択・中央へ・強調の地）だけ。
///
/// 本文の変更では一致を 100ms 後に取り直し（VS Code `FindModel` と同じ間引き。1MB の文書で打鍵ごとに全文を探さない）、
/// その間は編集に合わせて一致の区間をずらしておく。一致は俯瞰（ミニマップとスクロールバーの印）にも出るので、変わったら告げる。
@MainActor
final class EditorSearch {
  static let refreshDelay: TimeInterval = 0.1

  private(set) var needle = ""
  private(set) var matches: [NSRange] = []
  private(set) weak var document: EditorDocument?
  /// 件数が変わった（selected は 1 始まり。needle が空なら total 0 で届く。`limited` は上限で打ち切った）。
  var onCountChange: ((_ selected: Int?, _ total: Int, _ limited: Bool) -> Void)?
  /// 一致か現在の一致が変わった（俯瞰へ出し直す）。
  var onMatchesChange: (() -> Void)?
  /// needle が変わった（開閉を含む。出現の強調が検索と重ならないように）。
  var onNeedleChange: (() -> Void)?
  let refreshDelay = EditorDelay()

  /// 現在の一致——選択とちょうど重なる一致。
  var current: Int? {
    guard let selection = document?.surface.selectedRange else { return nil }
    return TextSearch.exact(in: matches, selection: selection)
  }

  /// 文書を結び直す。前の文書の地を消し、新しい文書に同じ needle で敷き直す（ジャンプしない）。
  func bind(_ document: EditorDocument?) {
    guard document !== self.document else { return }
    clearHighlights()
    self.document = document
    refresh()
  }

  /// needle が変わった。一致を取り直し、選択の先頭以降で最初の一致を選んで見せる。
  func setNeedle(_ needle: String) {
    self.needle = needle
    refresh()
    onNeedleChange?()
    guard let document,
      let index = TextSearch.current(in: matches, from: document.surface.selectedRange)
    else { return }
    reveal(index)
  }

  func next() {
    guard let document,
      let index = TextSearch.next(in: matches, from: document.surface.selectedRange)
    else { return }
    reveal(index)
  }

  func previous() {
    guard let document,
      let index = TextSearch.previous(in: matches, from: document.surface.selectedRange)
    else { return }
    reveal(index)
  }

  /// 本文が変わった。一致は編集に合わせてずらし、100ms 後に取り直す。選択は動かさない。
  func textDidChange(_ edit: TextEdit) {
    guard !needle.isEmpty else { return }
    matches = edit.track(matches)
    pushHighlights()
    refreshDelay.run(after: Self.refreshDelay) { [weak self] in self?.refresh() }
  }

  func selectionDidChange() {
    pushCurrent()
    pushCount()
    onMatchesChange?()
  }

  /// バーが閉じた。地を消す（選択は残る）。
  func close() {
    needle = ""
    matches = []
    refreshDelay.cancel()
    clearHighlights()
    onMatchesChange?()
    onNeedleChange?()
  }

  private func refresh() {
    refreshDelay.cancel()
    let text = needle.isEmpty ? nil : document?.surface.text
    matches = text.map { TextSearch.matches(of: needle, in: $0) } ?? []
    pushHighlights()
  }

  private func pushHighlights() {
    document?.surface.setHighlights(matches, for: .findMatch)
    pushCurrent()
    pushCount()
    onMatchesChange?()
  }

  private func pushCurrent() {
    document?.surface.setHighlights(current.map { [matches[$0]] } ?? [], for: .currentFindMatch)
  }

  private func clearHighlights() {
    document?.surface.setHighlights([], for: .findMatch)
    document?.surface.setHighlights([], for: .currentFindMatch)
  }

  /// 一致を選んで見せる——その行が縦に見えていなければ中央へ、見えていれば最小限のスクロールで（横に隠れて
  /// いれば横だけ寄る）。
  private func reveal(_ index: Int) {
    guard let document else { return }
    let match = matches[index]
    document.surface.selectedRange = match
    let (first, visible) = document.viewportLines
    let row = CGFloat(document.lineIndex.point(at: match.location).row)
    if row < first || row >= first + visible {
      document.surface.scrollToCenter(match.location)
    } else {
      document.surface.scrollToVisible(match)
    }
  }

  private func pushCount() {
    onCountChange?(current.map { $0 + 1 }, matches.count, TextSearch.isLimited(matches))
  }

  /// 俯瞰へ出す一致（現在の一致を含む）。
  var overview: (matches: [NSRange], current: NSRange?) {
    (matches, current.map { matches[$0] })
  }
}
