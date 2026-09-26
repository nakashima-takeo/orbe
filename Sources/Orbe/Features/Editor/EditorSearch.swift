import Foundation
import OrbeEditorCore

/// ファイル内検索の状態——needle・一致の列・結んだ文書・打ち直しの起点。「現在の一致」は持たず、選択から導く——選択が
/// ちょうど一致のどれかならそれ、そうでなければ無い（本文をクリック・打鍵して選択が一致から外れれば現在の地は消え、
/// 件数の位置は「?」）。Enter・⇧Enter の行き先は Core の規則（`TextSearch.next` / `previous`）。検索語を打つたびの
/// 行き先は、検索が選んだのではない最後のキャレットから（VS Code `FindModel` の start position）。選択の変化を観測して
/// 件数と現在の一致の地を導き直す。面への作用は契約（選択・キャレット・中央へ・強調の地）だけ。
///
/// 一致は文書の写しから裏で探す（`EditorDocument.analyze`）。検索語を打ち換えると、新しい検索語の一致が届くまで前の地と
/// 件数を出したままにし（打つたびに地が消えてちらつかない）、打鍵での最初の一致の選択と、その間に押された Enter・⇧Enter
/// （最後の 1 回ぶん）は届いてから新しい一致に対してその順に行う——前の検索語の一致へ飛ばない。待っている間に人が選択を
/// 動かせば、その後回しの操作は取り消す（届いた結果が人の選択を覆さない）。文書を切り替えたときも、新しい文書の一致が
/// 届くまで件数は前のまま（一致があるのに「一致なし」を一瞬出さない）。本文の変更では一致を 100ms 後に
/// 取り直し（VS Code `FindModel` と同じ間引き）、その間は編集に合わせて一致の区間をずらしておく。問いは同じなので、
/// 取り直しを待たずにずらした一致で操作できる。一致は俯瞰（ミニマップとスクロールバーの印）にも出るので、変わったら告げる。
@MainActor
final class EditorSearch {
  static let refreshDelay: TimeInterval = 0.1

  /// 一致を待っている間に、届いたら行う操作。
  private struct Awaiting {
    /// 起点以降の最初の一致を選ぶ（検索語を打ったとき）。
    var selectsFirst: Bool
    /// その後に当てる、最後に押された一歩。
    var step: Step?
  }

  /// Enter・⇧Enter の一歩。
  private enum Step {
    case next
    case previous
  }

  private(set) var needle = ""
  private(set) var matches: [NSRange] = []
  private(set) weak var document: EditorDocument?
  /// 検索語を打つたびに選ぶ一致の起点——検索が選んだのではない最後のキャレット。
  private var start = 0
  /// 最後に検索が選んだ一致（それ以外の選択の変化で起点を置き直す）。
  private var revealed: NSRange?
  /// 今の needle の一致がまだ届いていない間の、届いたら行う操作。
  private var awaiting: Awaiting?
  /// `matches` が結んだ文書の一致か（文書を切り替えてから新しい一致が届くまでは偽——その間は件数を送らず、前の件数を
  /// 出したままにする）。
  private var matchesBelongToDocument = true
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
    start = document?.surface.caretLocation ?? 0
    revealed = nil
    matches = []
    matchesBelongToDocument = false
    onMatchesChange?()
    search(selectingFirst: false)
  }

  /// needle が打ち込まれた。一致を取り直し、届いたら起点以降に始まる最初の一致を選んで見せる（VS Code の
  /// cursorMoveOnType）。同じ needle なら何もしない（⌘F の種をバーへ写したときの折り返し）。
  func setNeedle(_ needle: String) {
    guard needle != self.needle else { return }
    self.needle = needle
    search(selectingFirst: true)
    onNeedleChange?()
  }

  /// ⌘F の種を入れる。一致を取り直すだけで、選択は動かさない（VS Code の開いたときの検索）。
  func seed(_ needle: String) {
    self.needle = needle
    search(selectingFirst: false)
    onNeedleChange?()
  }

  func next() {
    guard awaiting == nil else {
      awaiting?.step = .next
      return
    }
    guard let document,
      let index = TextSearch.next(in: matches, from: document.surface.selectedRange)
    else { return }
    reveal(index)
  }

  func previous() {
    guard awaiting == nil else {
      awaiting?.step = .previous
      return
    }
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
    refreshDelay.run(after: Self.refreshDelay) { [weak self] in
      guard let self, let document, !needle.isEmpty else { return }
      document.analyze(.find(needle))
    }
  }

  /// 文書から一致が届いた（今の本文の上へずらしたもの）。今の needle の一致だけを受ける。
  func didFind(_ needle: String, _ ranges: [NSRange]) {
    guard needle == self.needle else { return }
    matches = ranges
    matchesBelongToDocument = true
    pushHighlights()
    guard let awaited = awaiting else { return }
    awaiting = nil
    if awaited.selectsFirst, let index = TextSearch.first(in: matches, from: start) {
      reveal(index)
    }
    switch awaited.step {
    case .next: next()
    case .previous: previous()
    case nil: break
    }
  }

  func selectionDidChange() {
    if let document, document.surface.selectedRange != revealed {
      start = document.surface.caretLocation
      revealed = nil
      awaiting?.selectsFirst = false
      awaiting?.step = nil
    }
    pushCurrent()
    pushCount()
    onMatchesChange?()
  }

  /// バーが閉じた。地を消す（選択は残る）。
  func close() {
    needle = ""
    matches = []
    matchesBelongToDocument = true
    awaiting = nil
    refreshDelay.cancel()
    clearHighlights()
    onMatchesChange?()
    onNeedleChange?()
  }

  /// 今の needle の一致を頼む。空なら一致を空にする。届くまでは前の一致と件数を出したままにし、`selectingFirst` なら届いた
  /// ときに起点以降の最初の一致を選ぶ。
  private func search(selectingFirst: Bool) {
    refreshDelay.cancel()
    guard let document, !needle.isEmpty else {
      awaiting = nil
      matches = []
      matchesBelongToDocument = true
      pushHighlights()
      return
    }
    awaiting = Awaiting(selectsFirst: selectingFirst, step: nil)
    document.analyze(.find(needle))
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
    revealed = match
    document.surface.selectedRange = match
    let (first, visible) = document.viewportLines
    let row = CGFloat(document.text.row(containing: match.location))
    if row < first || row >= first + visible {
      document.surface.scrollToCenter(match.location)
    } else {
      document.surface.scrollToVisible(match)
    }
  }

  private func pushCount() {
    guard matchesBelongToDocument else { return }
    onCountChange?(current.map { $0 + 1 }, matches.count, TextSearch.isLimited(matches))
  }

  /// 俯瞰へ出す一致（現在の一致を含む）。
  var overview: (matches: [NSRange], current: NSRange?) {
    (matches, current.map { matches[$0] })
  }
}
