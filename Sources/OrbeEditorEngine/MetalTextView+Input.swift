import AppKit
import OrbeEditorCore

/// IME（NSTextInputClient）。呼び出しの意味は NSTextView と同じ——範囲は場の文の座標（UTF-16）で、未確定の文字も文にある。
/// どの呼び出しも主の場（→ `MetalTextSurface.primarySite`）へ渡す。文を変える呼び出しは場の編集係の IME の入口へ渡し、
/// 読む呼び出しは編集の状態と取引の中の写しから答える（打鍵の取引の途中でも、IME が直後に読み返す値は最新）。
extension MetalTextView: @preconcurrency NSTextInputClient {
  /// 主の場（主が編集の場でなければ nil）。
  private var site: EditingSite? { surface?.primarySite }

  /// IME の呼び出しは面自身の入力（打鍵の中なら打鍵の処理の終わり、候補窓のクリックなど打鍵の外ならその場で出す）。
  func insertText(_ string: Any, replacementRange: NSRange) {
    guard let surface, let site else { return }
    let plain = (string as? NSAttributedString)?.string ?? string as? String ?? ""
    surface.inputScope {
      site.editor.insertText(surface.lineBreak.normalize(plain), replacement: replacementRange)
    }
  }

  func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
    guard let surface, let site else { return }
    let attributed =
      string as? NSAttributedString ?? NSAttributedString(string: string as? String ?? "")
    let (marked, selected) = Self.normalize(
      attributed, selected: selectedRange, to: surface.lineBreak)
    surface.inputScope {
      site.editor.setMarkedText(
        marked.string, selected: selected, replacement: replacementRange,
        appearance: Self.appearance(
          of: marked, selected: selected, appearance: effectiveAppearance, space: surface.space))
    }
  }

  func unmarkText() {
    guard let site else { return }
    surface?.inputScope { site.editor.unmarkText() }
  }

  func selectedRange() -> NSRange {
    guard let editor = site?.editor else { return NSRange(location: NSNotFound, length: 0) }
    return editor.composition?.selection ?? editor.state.cursors.primary.selection
  }

  func markedRange() -> NSRange {
    site?.editor.composition?.range ?? NSRange(location: NSNotFound, length: 0)
  }

  func hasMarkedText() -> Bool {
    site?.editor.isComposing ?? false
  }

  func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?)
    -> NSAttributedString?
  {
    guard let site, let text = site.editingEnvironment()?.text, range.location != NSNotFound,
      range.location < text.length
    else { return nil }
    let clipped = NSRange(
      location: range.location, length: min(NSMaxRange(range), text.length) - range.location)
    guard clipped.length > 0 else { return nil }
    actualRange?.pointee = clipped
    return NSAttributedString(string: text.substring(clipped), attributes: [.font: site.font])
  }

  func validAttributesForMarkedText() -> [NSAttributedString.Key] {
    [
      .underlineStyle, .underlineColor, .markedClauseSegment, .backgroundColor,
      NSAttributedString.Key("NSTextInputReplacementRangeAttributeName"),
    ]
  }

  /// 範囲の 1 行目の矩形（スクリーン座標）。範囲は 1 行目の中身の終わりで切り、文の外なら末尾の幅 0。変換中の未確定の
  /// 中は `MarkedLineGeometry` で答える（長い行でも打鍵ごとに行を組まない）。
  func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
    guard let site, let env = site.editingEnvironment(), let window else { return .zero }
    let text = env.text
    let location = min(
      max(0, range.location == NSNotFound ? text.length : range.location), text.length)
    let row = text.row(containing: location)
    let end = min(
      max(location, location + max(0, range.length)), NSMaxRange(text.contentRange(ofRow: row)))
    let clipped = NSRange(location: location, length: max(0, end - location))
    actualRange?.pointee = clipped
    return window.convertToScreen(
      convert(site.textRect(clipped, row: row, env, marked: site.markedLine), to: nil))
  }

  /// 点を含む字の位置（字の上でなければ NSNotFound——行末より右・字の無い行・文の外。macOS 26 の NSTextView と同じ）。
  func characterIndex(for point: NSPoint) -> Int {
    guard let site, let window else { return NSNotFound }
    let local = convert(window.convertPoint(fromScreen: point), from: nil)
    guard bounds.contains(local) else { return NSNotFound }
    if let marked = site.markedCharacter(at: local) { return marked }
    return site.character(at: local)?.location ?? NSNotFound
  }

  func baselineDeltaForCharacter(at anIndex: Int) -> CGFloat {
    guard let site else { return 0 }
    return site.lineHeight - site.baseline
  }

  func windowLevel() -> Int {
    window?.level.rawValue ?? 0
  }

  func drawsVerticallyForCharacter(at charIndex: Int) -> Bool { false }

  /// 点を含む字（`characterIndex(for:)` と同じ字）の左端から右端までのうち、点までの割合。
  func fractionOfDistanceThroughGlyph(for point: NSPoint) -> CGFloat {
    guard let site, let env = site.editingEnvironment(), let window else { return 0 }
    let local = convert(window.convertPoint(fromScreen: point), from: nil)
    guard let cluster = site.character(at: local) else { return 0 }
    let text = env.text
    let row = text.row(containing: cluster.location)
    let start = text.lineStart(row)
    let x = site.lineX(of: local)
    let ends = [cluster.location, NSMaxRange(cluster)].map {
      env.geometry.x(ofColumn: $0 - start, row: row)
    }
    let (x0, x1) = (ends.min() ?? 0, ends.max() ?? 0)
    return x1 > x0 ? min(max((x - x0) / (x1 - x0), 0), 1) : 0
  }

  /// 選択（変換中は IME の注目位置）の見えている部分の矩形（スクリーン座標）。キャレットは幅 0 の選択。
  var unionRectInVisibleSelectedRange: NSRect {
    guard let site, let env = site.editingEnvironment(), let window else { return .zero }
    let selection = selectedRange()
    let text = env.text
    let rows = text.rows(of: selection)
    let visible = site.visibleRows
    let first = min(max(rows.lowerBound, visible.lowerBound), rows.upperBound)
    let last = max(min(rows.upperBound, visible.upperBound), first)
    let marked = site.markedLine
    var union = NSRect.null
    for row in first...last {
      let content = text.contentRange(ofRow: row)
      let start = max(selection.location, text.lineStart(row))
      let end = min(NSMaxRange(selection), NSMaxRange(content))
      union = union.union(
        site.textRect(
          NSRange(location: start, length: max(0, end - start)), row: row, env, marked: marked))
    }
    let shown = union.intersection(site.textArea)
    return window.convertToScreen(convert(shown.isNull ? union : shown, to: nil))
  }

  /// 主の場の文の見えている区画（スクリーン座標）。
  var documentVisibleRect: NSRect {
    guard let window, let site else { return .zero }
    return window.convertToScreen(convert(site.textArea, to: nil))
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
  /// 中の選択に長さがあればそこを選んでいる文節にする。下線の色が透明なら指定が無いものとする。IME が指定した色は、他の
  /// 色と同じく外観 `appearance` で面の描く色空間 `space` に解く。
  static func appearance(
    of string: NSAttributedString, selected: NSRange, appearance: NSAppearance, space: CGColorSpace
  ) -> MarkedAppearance {
    let resolve = { (color: NSColor) in
      FrameColor(color, appearance: appearance, space: space).packed
    }
    var clauses: [MarkedClause] = []
    let whole = NSRange(location: 0, length: string.length)
    string.enumerateAttributes(in: whole) { attributes, range, _ in
      let style = (attributes[.underlineStyle] as? NSNumber)?.intValue
      guard
        style != nil || attributes[.markedClauseSegment] != nil
          || attributes[.backgroundColor] != nil
      else { return }
      let underline = (attributes[.underlineColor] as? NSColor).flatMap {
        $0.alphaComponent > 0 ? resolve($0) : nil
      }
      let clause = MarkedClause(
        range: range, active: (style ?? 0) & 0xFF >= NSUnderlineStyle.thick.rawValue,
        underline: underline,
        background: (attributes[.backgroundColor] as? NSColor).map(resolve))
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
/// Writing Tools は、面では働かない（コードを書く面なので）。AppKit の型は書き換えられる値として宣言するが、面は
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
