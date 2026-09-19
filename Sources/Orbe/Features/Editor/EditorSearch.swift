import Foundation
import OrbeEditorCore

/// ファイル内検索の状態——needle・一致の列・結んだ文書。「現在の一致」は持たず、選択から導く
/// （`TextSearch.current`）。選択の変化を観測して件数を導き直すので、Enter・⇧Enter・本文のクリック・打鍵の
/// どれでも同じ経路で件数が合う。規則は Core（`TextSearch`）、面への作用は契約（選択・中央へ・一致の地）だけ。
@MainActor
final class EditorSearch {
  private(set) var needle = ""
  private(set) var matches: [NSRange] = []
  private(set) weak var document: EditorDocument?
  /// 件数が変わった（selected は 1 始まり。needle が空なら total 0 で届く）。
  var onCountChange: ((_ selected: Int?, _ total: Int) -> Void)?

  /// 現在の一致（選択の関数）。
  var current: Int? {
    document.flatMap { TextSearch.current(in: matches, from: $0.surface.selectedRange) }
  }

  /// 文書を結び直す。前の文書の地を消し、新しい文書に同じ needle で敷き直す（ジャンプしない）。
  func bind(_ document: EditorDocument?) {
    guard document !== self.document else { return }
    self.document?.surface.setSearchHighlights([])
    self.document = document
    refresh()
  }

  /// needle が変わった。一致を取り直し、現在の一致を選んで見せる。
  func setNeedle(_ needle: String) {
    self.needle = needle
    refresh()
    if let current { reveal(current) }
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

  /// 本文が変わった。一致と件数だけ取り直し、選択は動かさない。
  func textDidChange() {
    refresh()
  }

  func selectionDidChange() {
    pushCount()
  }

  /// バーが閉じた。地を消す（選択は残る）。
  func close() {
    needle = ""
    matches = []
    document?.surface.setSearchHighlights([])
  }

  private func refresh() {
    let text = needle.isEmpty ? nil : document?.surface.text
    matches = text.map { TextSearch.matches(of: needle, in: $0) } ?? []
    document?.surface.setSearchHighlights(matches)
    pushCount()
  }

  /// 一致を選んで見せる——その行が縦に見えていなければ中央へ、見えていれば最小限のスクロールで（横に隠れて
  /// いれば横だけ寄る）。
  private func reveal(_ index: Int) {
    guard let document else { return }
    let match = matches[index]
    document.surface.selectedRange = match
    let viewport = document.surface.viewport
    let lineIndex = document.lineIndex
    let row = CGFloat(lineIndex.point(at: match.location).row)
    let first = CGFloat(lineIndex.point(at: viewport.firstVisible).row) + viewport.hiddenFraction
    if row < first || row >= first + viewport.visibleLines {
      document.surface.scrollToCenter(match.location)
    } else {
      document.surface.scrollToVisible(match)
    }
  }

  private func pushCount() {
    onCountChange?(current.map { $0 + 1 }, matches.count)
  }
}
