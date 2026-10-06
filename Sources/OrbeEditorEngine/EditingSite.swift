import AppKit
import OrbeEditorCore
import simd

/// 編集の場——面の中で編集を受ける文 1 つ。場は編集係（カーソル・undo・変換）・文の出どころ（`SiteText`）・入力の文脈を
/// 持ち、面の 1 つの取引・1 つのコマに乗る。面は view・材料の箱・出す口・スクロールの物理を 1 つずつ持つ単位で、場はその
/// 中で打つ単位——編集係・IME・コマンド・ペーストボード・マウスの選択は、面でなく場の口（取引・編集の環境・文への受け渡し・
/// 幾何）に依存する。
@MainActor
final class EditingSite {
  unowned let surface: MetalTextSurface
  let source: SiteText
  private(set) lazy var editor = SurfaceEditor(site: self)
  /// 入力の文脈（場ごとに 1 つ）。面の view は主の場の文脈を返す。テストは偽の IME に差し替える。
  lazy var inputContext: NSTextInputContext? = NSTextInputContext(client: surface.textView)
  /// 進行中の取引での、この場の取引の前の状態と差分（取引の外では nil）。
  var change: SiteChange?

  init(surface: MetalTextSurface, source: SiteText) {
    self.surface = surface
    self.source = source
  }

  // MARK: - 取引と文

  /// 取引の中で `body` を行う（→ `MetalTextSurface.transact`）。`reveal` は取引の後の見せ方（`range` は見せる区間、nil なら
  /// 主のキャレット。後から頼んだものが勝つ）、`remeasure` は最も長い行の測り直し。
  func transact(
    reveal: Reveal = .none, of range: NSRange? = nil, scrollTo: SIMD2<Double>? = nil,
    remeasure: Bool = false, _ body: () -> Void = {}
  ) {
    surface.transact(scrollTo: scrollTo) {
      if reveal != .none {
        surface.transaction?.reveal = reveal
        surface.transaction?.revealing = range
      }
      if remeasure { change?.remeasure = true }
      body()
    }
  }

  /// 今の写し（取引が引いた最新の写し、無ければまだ出していない写し、無ければ出した写し）。
  var currentContent: SurfaceContent? {
    change?.content ?? surface.pending.content ?? surface.material.read().content
  }

  var textLength: Int? { currentContent?.text.length }

  /// 編集の規則が読む環境。
  func editingEnvironment() -> EditingEnvironment? {
    guard let text = currentContent?.text else { return nil }
    let config = surface.config
    let lines = Int(
      (Double(surface.size.height - config.topInset) / Double(config.lineHeight)).rounded(.down))
    return EditingEnvironment(
      text: text,
      geometry: ShapedLineGeometry(
        text: text, cache: surface.lineStops,
        tabWidth: config.tabWidth(columns: surface.indentation.unit)),
      pageLines: max(1, lines - 2), rows: surface.rows, indentation: surface.indentation,
      lineBreak: surface.lineBreak, killBuffer: KillBuffer.contents)
  }

  /// 編集の束を 1 回で文の出どころへ渡し、戻ったら写しを引く（取引の中だけ）。束を当てた後の文を返す（結ばれていなければ
  /// nil）。
  func deliver(_ batch: EditBatch) -> TextRope? {
    precondition(change != nil, "場の文の変化は取引の中でだけ渡す")
    guard let before = currentContent?.text else { return nil }
    source.apply(batch.edits)
    guard let content = source.content else { return nil }
    change?.content = content
    change?.edited = true
    // 束は後ろから当たる。後ろの編集は前の行を動かさないので、どの編集の行も束の前の文で数えられる。
    let edits = batch.edits.reversed().map { RowEdit($0, in: before, version: content.version) }
    change?.rowEdits += edits
    for edit in edits { surface.rows.shift(edit) }
    return content.text
  }

  /// 取引の中で、カーソルの列を ⌘U で戻した（カーソルの履歴に積まない）。
  func markCursorsRestored() {
    change?.restoresCursors = true
  }

  /// 変換の文字の座標が変わった（候補窓を追従させる）。
  func inputMethodCoordinatesDidChange() {
    inputContext?.invalidateCharacterCoordinates()
  }

  // MARK: - 幾何（view の座標、pt）

  /// 点の場所と、いちばん近い書記素の境（→ `MetalTextSurface.hit`）。
  func hit(_ point: CGPoint, position: SIMD2<Double>? = nil) -> PointerHit? {
    surface.hit(point, position: position)
  }

  /// 点を含む書記素（→ `MetalTextSurface.character(at:)`）。
  func character(at point: CGPoint, position: SIMD2<Double>? = nil) -> NSRange? {
    surface.character(at: point, position: position)
  }

  /// 文の見えている区画（上端の余白の下）。
  var textArea: NSRect {
    let area = surface.surfaceLayout.text
    let top = surface.config.topInset
    return NSRect(x: area.minX, y: top, width: area.width, height: max(0, area.height - top))
  }

  /// 見えている行の範囲（文の行）。
  var visibleRows: ClosedRange<Int> {
    let y = surface.scrollPosition.y
    let top = surface.rows.line(atY: y)
    let bottom = surface.rows.line(atY: y + Double(surface.size.height))
    return top...max(top, bottom)
  }

  /// 文の字体と行の高さ、行の上端から基線まで。
  var font: NSFont { surface.config.font as NSFont }
  var lineHeight: CGFloat { surface.config.lineHeight }
  var baseline: CGFloat { surface.config.baseline }

  /// 1 行の中の範囲の矩形（行の高さいっぱい）。未確定の行の未確定の中の端は `marked` で出す。
  func textRect(
    _ range: NSRange, row: Int, _ env: EditingEnvironment, marked: MarkedLineGeometry?
  ) -> NSRect {
    let start = env.text.lineStart(row)
    let onMarked = marked?.row == row ? marked : nil
    let x0 =
      onMarked?.x(of: range.location) ?? env.geometry.x(ofColumn: range.location - start, row: row)
    let x1 =
      onMarked?.x(of: NSMaxRange(range))
      ?? env.geometry.x(ofColumn: NSMaxRange(range) - start, row: row)
    let p = surface.scrollPosition
    let config = surface.config
    return NSRect(
      x: config.columnWidth(lineCount: env.text.lineCount) + x0 - CGFloat(p.x),
      y: config.topInset + CGFloat(surface.rows.y(ofLine: row) - p.y), width: x1 - x0,
      height: config.lineHeight)
  }

  /// 変換中の未確定の横位置（変換中でなければ nil）。
  var markedLine: MarkedLineGeometry? {
    guard let composition = editor.composition, let text = currentContent?.text else { return nil }
    return MarkedLineGeometry(
      composition, text: text, cache: surface.lineStops,
      tabWidth: surface.config.tabWidth(columns: surface.indentation.unit))
  }

  /// 点を含む未確定の字の位置（点が未確定の字の上でなければ nil）。
  func markedCharacter(at point: CGPoint) -> Int? {
    guard let marked = markedLine, let text = currentContent?.text else { return nil }
    let config = surface.config
    let p = surface.scrollPosition
    let column = config.columnWidth(lineCount: text.lineCount)
    let y = Double(point.y - config.topInset) + p.y
    guard point.x >= column, point.y >= config.topInset,
      surface.rows.item(atY: y) == .line(marked.row),
      let offset = marked.offset(containingX: point.x - column + CGFloat(p.x))
    else { return nil }
    return text.grapheme(containing: offset).location
  }

  /// 行頭からの点の x。
  func lineX(of point: CGPoint) -> CGFloat {
    let lineCount = currentContent?.text.lineCount ?? 1
    return point.x - surface.config.columnWidth(lineCount: lineCount)
      + CGFloat(surface.scrollPosition.x)
  }
}

/// 進行中の取引での、場 1 つの取引の前の状態と差分。
struct SiteChange {
  /// 取引の前のカーソルの列と ⌘D の続きと、変換中だったか。
  let cursors: CursorList
  let continuation: SearchQuestion?
  let composing: Bool
  /// 取引の中で引いた写し（引かなければ nil）。
  var content: SurfaceContent?
  /// 取引の中で渡した編集で、組版の変わった行（当てた順）。
  var rowEdits: [RowEdit] = []
  /// 文を変えたか。
  var edited = false
  /// カーソルの列を ⌘U で戻した。
  var restoresCursors = false
  /// 最も長い行を測り直す（丸ごと置き換え）。
  var remeasure = false

  @MainActor init(_ editor: SurfaceEditor) {
    cursors = editor.state.cursors
    continuation = editor.state.continuation
    composing = editor.isComposing
  }
}

/// 本文の場の文の出どころ——面の delegate（文書）を場の口に包む。
@MainActor
final class DocumentText: SiteText {
  private unowned let surface: MetalTextSurface

  init(surface: MetalTextSurface) {
    self.surface = surface
  }

  func apply(_ edits: [TextEdit]) {
    surface.delegate?.surface(surface, didChange: edits)
  }

  var content: SurfaceContent? { surface.delegate?.surfaceContent(surface) }
}
