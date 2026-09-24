import Foundation
import OrbeEditorCore

/// 出現の強調の状態（pane ごと）——選択文字列の他の出現と、キャレットの語の出現。規則は Core（`Occurrences`）、面への
/// 作用は契約（強調の地）だけ。語の出現は俯瞰（スクロールバーの印とミニマップ）にも出るので、変わったら告げる。
///
/// 時間の規則は VS Code と同じ。選択文字列の出現は選択の変化で即時、本文の変更で 300ms 後に取り直す。語の出現は
/// キャレットの明示的な移動から 50ms 後に出て、打鍵・本文の変更で消え、キャレットが出ている範囲の中を動く間は取り直さない。
/// 「明示的な移動」は、同じ runloop の中に本文の変更を伴わない選択の変化とする（打鍵は本文の変更と選択の変化が同じ
/// runloop に来る。エンジンの契約に変化の理由は無い）。焦点がエディター面（テキスト面と検索バー）の外へ出ると語の出現は
/// 消え、テキスト面へ戻るとキャレットを動かさなくても出直す。
@MainActor
final class EditorOccurrences {
  static let wordDelay: TimeInterval = 0.05
  static let selectionDelay: TimeInterval = 0.3

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
  let selectionDelay = EditorDelay()
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

  func textDidChange(_ edit: TextEdit) {
    textChangedThisTurn = true
    DispatchQueue.main.async { [weak self] in self?.textChangedThisTurn = false }
    clearWord()
    setSelectionOccurrences(edit.track(selectionOccurrences))
    selectionDelay.run(after: Self.selectionDelay) { [weak self] in
      self?.updateSelectionOccurrences()
    }
  }

  /// テキスト面の焦点が変わった。`insideFace` は焦点がまだエディター面（検索バーを含む）の中にあるか。
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
    let selection = document.surface.selectedRange
    let index = document.lineIndex
    let row = index.point(at: selection.location).row
    var line = NSRange(location: index.start(ofRow: row), length: 0)
    line.length = index.end(ofRow: row) - line.location
    var body = Array(document.surface.substring(in: line).utf16)
    if body.last == 0x0A { body.removeLast() }
    if body.last == 0x0D { body.removeLast() }
    let word = Occurrences.word(
      at: selection, line: String(utf16CodeUnits: body, count: body.count),
      lineStart: line.location)
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
