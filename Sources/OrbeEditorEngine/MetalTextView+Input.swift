import AppKit
import OrbeEditorCore

/// IME（NSTextInputClient）。呼び出しの意味は NSTextView と同じ——範囲は文書の座標（UTF-16）で、未確定の文字も本文にある。
/// 本文を変える呼び出しは面の編集係の IME の入口へ渡し、読む呼び出しは編集の状態と取引の中の写しから答える（打鍵の取引の
/// 途中でも、IME が直後に読み返す値は最新）。
extension MetalTextView: @preconcurrency NSTextInputClient {
  private var editor: SurfaceEditor? { surface?.editor }

  func insertText(_ string: Any, replacementRange: NSRange) {
    guard let surface else { return }
    let plain = (string as? NSAttributedString)?.string ?? string as? String ?? ""
    surface.editor.insertText(surface.lineBreak.normalize(plain), replacement: replacementRange)
  }

  func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
    guard let surface else { return }
    let attributed =
      string as? NSAttributedString ?? NSAttributedString(string: string as? String ?? "")
    let (marked, selected) = Self.normalize(
      attributed, selected: selectedRange, to: surface.lineBreak)
    surface.editor.setMarkedText(
      marked.string, selected: selected, replacement: replacementRange,
      appearance: Self.appearance(of: marked, selected: selected))
  }

  func unmarkText() {
    editor?.unmarkText()
  }

  func selectedRange() -> NSRange {
    guard let editor else { return NSRange(location: NSNotFound, length: 0) }
    return editor.composition?.selection ?? editor.state.cursors.primary.selection
  }

  func markedRange() -> NSRange {
    editor?.composition?.range ?? NSRange(location: NSNotFound, length: 0)
  }

  func hasMarkedText() -> Bool {
    editor?.isComposing ?? false
  }

  func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?)
    -> NSAttributedString?
  {
    guard let surface, let text = surface.editingEnvironment()?.text, range.location != NSNotFound,
      range.location < text.length
    else { return nil }
    let clipped = NSRange(
      location: range.location, length: min(NSMaxRange(range), text.length) - range.location)
    guard clipped.length > 0 else { return nil }
    actualRange?.pointee = clipped
    return NSAttributedString(
      string: text.substring(clipped), attributes: [.font: surface.config.font as NSFont])
  }

  func validAttributesForMarkedText() -> [NSAttributedString.Key] {
    [
      .underlineStyle, .underlineColor, .markedClauseSegment, .backgroundColor,
      NSAttributedString.Key("NSTextInputReplacementRangeAttributeName"),
    ]
  }

  /// 範囲の 1 行目の矩形（スクリーン座標）。範囲は 1 行目の中身の終わりで切り、本文の外なら末尾の幅 0。
  func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
    guard let surface, let env = surface.editingEnvironment(), let window else { return .zero }
    let text = env.text
    let location = min(
      max(0, range.location == NSNotFound ? text.length : range.location), text.length)
    let row = text.row(containing: location)
    let end = min(
      max(location, location + max(0, range.length)), NSMaxRange(text.contentRange(ofRow: row)))
    let clipped = NSRange(location: location, length: max(0, end - location))
    actualRange?.pointee = clipped
    return window.convertToScreen(convert(textRect(clipped, row: row, env), to: nil))
  }

  func characterIndex(for point: NSPoint) -> Int {
    guard let surface, let window else { return NSNotFound }
    let local = convert(window.convertPoint(fromScreen: point), from: nil)
    guard bounds.contains(local), let hit = surface.hit(local), hit.area == .text, isOnText(local)
    else { return NSNotFound }
    return hit.offset
  }

  func baselineDeltaForCharacter(at anIndex: Int) -> CGFloat {
    guard let config = surface?.config else { return 0 }
    return config.lineHeight - config.baseline
  }

  func windowLevel() -> Int {
    window?.level.rawValue ?? 0
  }

  func drawsVerticallyForCharacter(at charIndex: Int) -> Bool { false }

  /// 点の下の字の左端から右端までのうち、点までの割合。
  func fractionOfDistanceThroughGlyph(for point: NSPoint) -> CGFloat {
    guard let surface, let env = surface.editingEnvironment(), let window else { return 0 }
    let local = convert(window.convertPoint(fromScreen: point), from: nil)
    guard let hit = surface.hit(local), hit.area == .text else { return 0 }
    let text = env.text
    let start = text.lineStart(hit.row)
    let x =
      local.x - surface.config.columnWidth(lineCount: text.lineCount) + CGFloat(scrollPosition.x)
    let inside =
      x < env.geometry.x(ofColumn: hit.offset - start, row: hit.row) ? hit.offset - 1 : hit.offset
    guard inside >= start, inside < NSMaxRange(text.contentRange(ofRow: hit.row)) else { return 0 }
    let cluster = text.grapheme(containing: inside)
    let x0 = env.geometry.x(ofColumn: cluster.location - start, row: hit.row)
    let x1 = env.geometry.x(ofColumn: NSMaxRange(cluster) - start, row: hit.row)
    return x1 > x0 ? min(max((x - x0) / (x1 - x0), 0), 1) : 0
  }

  /// 選択（変換中は IME の注目位置）の見えている部分の矩形（スクリーン座標）。キャレットは幅 0 の選択。
  var unionRectInVisibleSelectedRange: NSRect {
    guard let surface, let env = surface.editingEnvironment(), let window else { return .zero }
    let selection = selectedRange()
    let text = env.text
    let rows = text.rows(of: selection)
    let top = Int((scrollPosition.y / Double(surface.config.lineHeight)).rounded(.down))
    let bottom = top + Int((Double(bounds.height) / Double(surface.config.lineHeight)).rounded(.up))
    let first = min(max(rows.lowerBound, top), rows.upperBound)
    let last = max(min(rows.upperBound, bottom), first)
    var union = NSRect.null
    for row in first...last {
      let content = text.contentRange(ofRow: row)
      let start = max(selection.location, text.lineStart(row))
      let end = min(NSMaxRange(selection), NSMaxRange(content))
      union = union.union(
        textRect(NSRange(location: start, length: max(0, end - start)), row: row, env))
    }
    let visible = union.intersection(textArea)
    return window.convertToScreen(convert(visible.isNull ? union : visible, to: nil))
  }

  /// 本文の見えている区画（行番号の列の右・上端の余白の下。スクリーン座標）。
  var documentVisibleRect: NSRect {
    guard let window else { return .zero }
    return window.convertToScreen(convert(textArea, to: nil))
  }

  // MARK: - 座標

  /// 今のスクロールの位置（取引の中で置いた位置があればそれ）。
  private var scrollPosition: SIMD2<Double> { surface?.scrollPosition ?? .zero }

  /// 本文の区画（view の座標）。
  private var textArea: NSRect {
    guard let surface else { return .zero }
    let lineCount = surface.editingEnvironment()?.text.lineCount ?? 1
    let column = surface.config.columnWidth(lineCount: lineCount)
    return NSRect(
      x: column, y: surface.config.topInset, width: max(0, bounds.width - column),
      height: max(0, bounds.height - surface.config.topInset))
  }

  /// 1 行の中の範囲の矩形（view の座標。行の高さいっぱい）。
  private func textRect(_ range: NSRange, row: Int, _ env: EditingEnvironment) -> NSRect {
    guard let surface else { return .zero }
    let start = env.text.lineStart(row)
    let x0 = env.geometry.x(ofColumn: range.location - start, row: row)
    let x1 = env.geometry.x(ofColumn: NSMaxRange(range) - start, row: row)
    let p = scrollPosition
    let config = surface.config
    return NSRect(
      x: config.columnWidth(lineCount: env.text.lineCount) + x0 - CGFloat(p.x),
      y: config.topInset + CGFloat(row) * config.lineHeight - CGFloat(p.y), width: x1 - x0,
      height: config.lineHeight)
  }

  /// 点が本文の行の上か（最終行より下の空き地でない）。
  private func isOnText(_ point: CGPoint) -> Bool {
    guard let surface, let text = surface.editingEnvironment()?.text else { return false }
    let y = Double(point.y - surface.config.topInset) + scrollPosition.y
    return y >= 0 && y < Double(text.lineCount) * Double(surface.config.lineHeight)
  }

  // MARK: - 未確定の文字

  /// 未確定の文字の改行を文書の作法へ揃え、中の選択をずらす。
  private static func normalize(
    _ string: NSAttributedString, selected: NSRange, to lineBreak: LineBreak
  ) -> (NSAttributedString, NSRange) {
    let units = Array(string.string.utf16)
    guard units.contains(where: { $0 == 0x0A || $0 == 0x0D }) else { return (string, selected) }
    let result = NSMutableAttributedString(attributedString: string)
    var location = selected.location
    var end = NSMaxRange(selected)
    var index = units.count - 1
    while index >= 0 {
      defer { index -= 1 }
      guard units[index] == 0x0A || units[index] == 0x0D else { continue }
      let pair = units[index] == 0x0A && index > 0 && units[index - 1] == 0x0D
      let range = NSRange(location: pair ? index - 1 : index, length: pair ? 2 : 1)
      if pair { index -= 1 }
      guard result.attributedSubstring(from: range).string != lineBreak.string else { continue }
      let delta = lineBreak.string.utf16.count - range.length
      result.replaceCharacters(in: range, with: lineBreak.string)
      if range.location < location { location += delta }
      if range.location < end { end += delta }
    }
    return (result, NSRange(location: location, length: max(0, end - location)))
  }

  /// 未確定の文字の見た目。下線・文節・地の属性があれば文節の列（IME が選んでいるのは太い下線の文節）、無ければ地で塗り、
  /// 中の選択に長さがあればそこを選んでいる文節にする。下線の色が透明なら指定が無いものとする。
  static func appearance(of string: NSAttributedString, selected: NSRange) -> MarkedAppearance {
    var clauses: [MarkedClause] = []
    let whole = NSRange(location: 0, length: string.length)
    string.enumerateAttributes(in: whole) { attributes, range, _ in
      let style = (attributes[.underlineStyle] as? NSNumber)?.intValue
      guard
        style != nil || attributes[.markedClauseSegment] != nil
          || attributes[.backgroundColor] != nil
      else { return }
      let underline = (attributes[.underlineColor] as? NSColor).flatMap {
        $0.alphaComponent > 0 ? FrameColor.pack($0) : nil
      }
      let clause = MarkedClause(
        range: range, active: (style ?? 0) & 0xFF >= NSUnderlineStyle.thick.rawValue,
        underline: underline,
        background: (attributes[.backgroundColor] as? NSColor).map(FrameColor.pack))
      if let last = clauses.last, NSMaxRange(last.range) == range.location,
        last.active == clause.active,
        last.underline == clause.underline, last.background == clause.background,
        attributes[.markedClauseSegment] == nil
      {
        clauses[clauses.count - 1].range.length += range.length
      } else {
        clauses.append(clause)
      }
    }
    guard clauses.isEmpty else { return MarkedAppearance(clauses: clauses, filled: false) }
    let active =
      selected.length > 0
      ? [MarkedClause(range: selected, active: true, underline: nil, background: nil)] : []
    return MarkedAppearance(clauses: active, filled: true)
  }
}

// swiftlint:disable unused_setter_value
/// 自動修正・スペル・引用符とダッシュの置換・テキストの置換・データとリンクの検出・補完・予測入力・数式の補完・
/// Writing Tools は、新しい面では働かない（コードを書く面なので）。AppKit の型は書き換えられる値として宣言するが、面は
/// 常に切る（書かれても受けない）。
extension MetalTextView: @preconcurrency NSTextInputTraits {
  var autocorrectionType: NSTextInputTraitType {
    get { .no }
    set {}
  }
  var spellCheckingType: NSTextInputTraitType {
    get { .no }
    set {}
  }
  var grammarCheckingType: NSTextInputTraitType {
    get { .no }
    set {}
  }
  var smartQuotesType: NSTextInputTraitType {
    get { .no }
    set {}
  }
  var smartDashesType: NSTextInputTraitType {
    get { .no }
    set {}
  }
  var smartInsertDeleteType: NSTextInputTraitType {
    get { .no }
    set {}
  }
  var textReplacementType: NSTextInputTraitType {
    get { .no }
    set {}
  }
  var dataDetectionType: NSTextInputTraitType {
    get { .no }
    set {}
  }
  var linkDetectionType: NSTextInputTraitType {
    get { .no }
    set {}
  }
  var textCompletionType: NSTextInputTraitType {
    get { .no }
    set {}
  }
  var inlinePredictionType: NSTextInputTraitType {
    get { .no }
    set {}
  }
  @available(macOS 15.0, *)
  var mathExpressionCompletionType: NSTextInputTraitType {
    get { .no }
    set {}
  }
  @available(macOS 15.0, *)
  var writingToolsBehavior: NSWritingToolsBehavior {
    get { .none }
    set {}
  }
}
// swiftlint:enable unused_setter_value
