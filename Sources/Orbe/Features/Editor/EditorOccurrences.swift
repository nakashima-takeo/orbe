import Foundation
import OrbeEditorCore

/// 出現の強調の状態（pane ごと）——選択文字列の他の出現と、キャレットの語の出現。規則は Core（`Occurrences`）、面への
/// 作用は契約（強調の地）だけ。語の出現は俯瞰（スクロールバーの印とミニマップ）にも出るので、変わったら告げる。
///
/// 出現は文書の写しから裏で探し（`EditorDocument.analyze`）、届いた結果のうち今の問いのものだけを出す。選択文字列の出現は
/// 選択の変化で即時に頼む（本文を変える操作——打鍵・undo・大文字化・丸ごと置き換え——はどれも本文の変化の後に選択の
/// 変化を伴うので、本文の変化では頼まない）。語の出現はキャレットの明示的な移動から 50ms 後に
/// 出て（VS Code と同じ）、打鍵・本文の変更で消え、キャレットが出ている範囲の中を動く間は取り直さない。
/// 「明示的な移動」は、同じ runloop の中に本文の変更を伴わない選択の変化とする（打鍵は本文の変更と選択の変化が同じ
/// runloop に来る。エンジンの契約に変化の理由は無い）。焦点がテキスト面と検索バーの外へ出ると語の出現は消え、テキスト面へ
/// 戻るとキャレットを動かさなくても出直す。
@MainActor
final class EditorOccurrences {
  static let wordDelay: TimeInterval = 0.05

  private(set) weak var document: EditorDocument?
  private(set) var selectionOccurrences: [NSRange] = []
  /// 結果を待っている問い（届いた結果のうち、これと同じ問いのものだけを出す）。
  private var selectionRequest: AnalysisRequest?
  private var wordRequest: AnalysisRequest?
  private(set) var wordOccurrences: [NSRange] = [] {
    didSet { if wordOccurrences != oldValue { onWordOccurrencesChange?() } }
  }
  var onWordOccurrencesChange: (() -> Void)?
  /// 検索バーの検索語（バーが開いている間。閉じていれば nil）と、入力欄に焦点があるか。
  private var findNeedle: String?
  private var findFieldFocused = false
  /// テキスト面に焦点があるか。
  private var surfaceFocused = false
  let wordDelay = EditorDelay()
  /// この runloop に本文の変更があった（打鍵に伴う選択の変化を明示的な移動と見なさない）。
  private var textChangedThisTurn = false

  func bind(_ document: EditorDocument?) {
    guard document !== self.document else { return }
    clearWord()
    selectionRequest = nil
    setSelectionOccurrences([])
    self.document = document
    surfaceFocused =
      document.map { $0.surface.responder.window?.firstResponder === $0.surface.responder }
      ?? false
    updateSelectionOccurrences()
    if surfaceFocused { scheduleWord() }
  }

  func selectionDidChange() {
    updateSelectionOccurrences()
    guard surfaceFocused, !textChangedThisTurn else { return }
    if let caret = document?.surface.selectedRange,
      wordOccurrences.contains(where: {
        $0.location <= caret.location && NSMaxRange(caret) <= NSMaxRange($0)
      })
    {
      return
    }
    scheduleWord()
  }

  func textDidChange() {
    textChangedThisTurn = true
    DispatchQueue.main.async { [weak self] in self?.textChangedThisTurn = false }
    clearWord()
  }

  /// 焦点が変わった。`surfaceFocused` はテキスト面に焦点があるか、`insideFace` は焦点がテキスト面か検索バーにあるか。
  func focusDidChange(surfaceFocused: Bool, insideFace: Bool) {
    self.surfaceFocused = surfaceFocused
    if surfaceFocused {
      scheduleWord()
    } else if !insideFace {
      clearWord()
    }
  }

  /// 検索バーの状態が変わった（開閉・検索語・入力欄の焦点）。
  func findStateDidChange(needle: String?, fieldFocused: Bool) {
    findNeedle = needle
    findFieldFocused = fieldFocused
    updateSelectionOccurrences()
  }

  /// 文書から選択文字列の出現が届いた。
  func didFindSelectionOccurrences(_ request: AnalysisRequest, _ ranges: [NSRange]) {
    guard request == selectionRequest else { return }
    selectionRequest = nil
    setSelectionOccurrences(ranges)
  }

  /// 文書から語の出現が届いた。
  func didFindWordOccurrences(_ request: AnalysisRequest, _ ranges: [NSRange]) {
    guard request == wordRequest else { return }
    wordRequest = nil
    wordOccurrences = ranges
    document?.surface.setHighlights(ranges, for: .wordOccurrence)
  }

  private func updateSelectionOccurrences() {
    guard let document else { return }
    let selection = document.surface.selectedRange
    guard selection.length > 0, selection.length <= Occurrences.maxSelectionLength else {
      selectionRequest = nil
      setSelectionOccurrences([])
      return
    }
    let request = AnalysisRequest.selectionOccurrences(
      selection: selection, findNeedle: findNeedle, findFieldFocused: findFieldFocused)
    guard request != selectionRequest else { return }
    selectionRequest = request
    document.analyze(request)
  }

  private func setSelectionOccurrences(_ ranges: [NSRange]) {
    selectionOccurrences = ranges
    document?.surface.setHighlights(ranges, for: .selectionOccurrence)
  }

  private func scheduleWord() {
    wordDelay.run(after: Self.wordDelay) { [weak self] in self?.updateWord() }
  }

  private func updateWord() {
    guard let document, surfaceFocused else { return }
    guard let word = document.word(at: document.surface.selectedRange) else {
      wordRequest = nil
      wordOccurrences = []
      document.surface.setHighlights([], for: .wordOccurrence)
      return
    }
    let request = AnalysisRequest.wordOccurrences(word)
    wordRequest = request
    document.analyze(request)
  }

  private func clearWord() {
    wordDelay.cancel()
    wordRequest = nil
    wordOccurrences = []
    document?.surface.setHighlights([], for: .wordOccurrence)
  }
}
