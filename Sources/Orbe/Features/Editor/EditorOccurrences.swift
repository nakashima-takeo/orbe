import Foundation
import OrbeEditorCore

/// 出現の強調の状態（pane ごと）——選択文字列の他の出現と、キャレットの語の出現。規則は Core（`Occurrences`）、面への
/// 作用は契約（強調の地）だけ。語の出現は俯瞰（スクロールバーの印とミニマップ）にも出るので、変わったら告げる。
///
/// 選択文字列の出現は選択の変化で即時に取り直す（本文を変える操作——打鍵・undo・大文字化・丸ごと置き換え——はどれも
/// 本文の変化の後に選択の変化を伴うので、本文の変化では取り直さない）。語の出現はキャレットの明示的な移動から 50ms 後に
/// 出て（VS Code と同じ）、打鍵・本文の変更で消え、キャレットが出ている範囲の中を動く間は取り直さない。
/// 「明示的な移動」は、同じ runloop の中に本文の変更を伴わない選択の変化とする（打鍵は本文の変更と選択の変化が同じ
/// runloop に来る。エンジンの契約に変化の理由は無い）。焦点がテキスト面と検索バーの外へ出ると語の出現は消え、テキスト面へ
/// 戻るとキャレットを動かさなくても出直す。
@MainActor
final class EditorOccurrences {
  static let wordDelay: TimeInterval = 0.05

  private(set) weak var document: EditorDocument?
  private(set) var selectionOccurrences: [NSRange] = []
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

  private func updateSelectionOccurrences() {
    guard let document else { return }
    let selection = document.surface.selectedRange
    guard selection.length > 0, selection.length <= Occurrences.maxSelectionLength else {
      setSelectionOccurrences([])
      return
    }
    setSelectionOccurrences(
      Occurrences.selectionOccurrences(
        of: document.surface.selectedRange, in: document.surface.text, findNeedle: findNeedle,
        findFieldFocused: findFieldFocused))
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
    let word = document.word(at: document.surface.selectedRange)
    wordOccurrences =
      word.map { Occurrences.wordOccurrences(of: $0, in: document.surface.text) } ?? []
    document.surface.setHighlights(wordOccurrences, for: .wordOccurrence)
  }

  private func clearWord() {
    wordDelay.cancel()
    wordOccurrences = []
    document?.surface.setHighlights([], for: .wordOccurrence)
  }
}
