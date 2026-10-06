import AppKit
import OrbeEditorCore
import simd

/// 編集の場——面の中で編集を受ける文 1 つ。本文（文書）と、区画の入力欄（`ZoneTextField`）が場になる。場は編集係
/// （カーソル・undo・変換）・文の出どころ（`SiteText`）・入力の文脈を持ち、面の 1 つの取引・1 つのコマに乗る。面は view・
/// 材料の箱・出す口・スクロールの物理を 1 つずつ持つ単位で、場はその中で打つ単位——編集係・IME・コマンド・ペーストボード・
/// マウスの選択は、面でなく場の口（取引・編集の環境・文への受け渡し・幾何・見せ方）に依存する。
///
/// 入力欄の場は区画の絵の中の矩形に 1 行ずつ字を置き（折り返さない）、縦にはスクロールしない——縦に見せるのは面の縦の
/// 位置で、長い行は場の横の送り（`scrollX`）でキャレットに追従する。
@MainActor
final class EditingSite {
  enum Kind {
    case body
    case field(ZoneTextField)
  }

  unowned let surface: MetalTextSurface
  let kind: Kind
  let source: SiteText
  /// 材料の箱で入力欄の場を引く通し番号（本文は 0）。
  let serial: Int
  private(set) lazy var editor = SurfaceEditor(site: self)
  /// 入力の文脈（場ごとに 1 つ——macOS の入力ソースの書類ごとの切り替えが場ごとに効く）。面の view は主の場の文脈を
  /// 返す。テストは偽の IME に差し替える。
  lazy var inputContext: NSTextInputContext? = NSTextInputContext(client: surface.textView)
  /// 進行中の取引での、この場の取引の前の状態と差分（取引の外では nil）。
  var change: SiteChange?
  /// 入力欄の場を描いている区画と、区画の中の文を打つ矩形（入力欄の場だけ。どの区画の絵にも無ければ nil）。
  var zone: ObjectIdentifier?
  var frame = CGRect.zero
  /// 横の送り（入力欄の場だけ。pt）。
  var scrollX: Double = 0
  /// 入力欄の場の外観で解いた色（外観が変われば解き直す）。
  var palette: FieldPalette?
  private let fieldStops: LineStopsCache?

  init(surface: MetalTextSurface, body source: SiteText) {
    self.surface = surface
    kind = .body
    self.source = source
    serial = 0
    fieldStops = nil
  }

  init(surface: MetalTextSurface, field: ZoneTextField, serial: Int) {
    self.surface = surface
    kind = .field(field)
    source = field
    self.serial = serial
    fieldStops = LineStopsCache(font: field.style.font as CTFont)
  }

  var isBody: Bool {
    if case .body = kind { return true }
    return false
  }

  var field: ZoneTextField? {
    if case .field(let field) = kind { return field }
    return nil
  }

  // MARK: - 取引と文

  /// 取引の中で `body` を行う（→ `MetalTextSurface.transact`）。`reveal` は取引の後の見せ方（`range` は見せる区間、nil なら
  /// 主のキャレット。後から頼んだものが勝つ）、`remeasure` は最も長い行の測り直し（本文の場）。
  func transact(
    reveal: Reveal = .none, of range: NSRange? = nil, scrollTo: SIMD2<Double>? = nil,
    remeasure: Bool = false, _ body: () -> Void = {}
  ) {
    surface.transact(scrollTo: scrollTo) {
      touch()
      if reveal != .none {
        surface.transaction?.reveal = reveal
        surface.transaction?.revealing = range
        surface.transaction?.revealSite = self
      }
      if remeasure { change?.remeasure = true }
      body()
    }
  }

  /// 取引の中でこの場に触れる（初めてなら取引の前の状態を控え、確定の対象にする）。本文の場は取引を開くときに控える。
  func touch() {
    guard change == nil else { return }
    change = SiteChange(editor)
    surface.transaction?.touched.append(self)
  }

  /// 今の写し。本文の場は、取引が引いた最新の写し、無ければまだ出していない写し、無ければ出した写し。入力欄の場は入力欄の
  /// 今の文。
  var currentContent: SurfaceContent? {
    guard isBody else { return source.content }
    return change?.content ?? surface.pending.content ?? surface.material.read().content
  }

  var textLength: Int? { currentContent?.text.length }

  /// 改行の作法（本文の場は文書の作法、入力欄は LF）。
  var lineBreak: LineBreak { isBody ? surface.lineBreak : .lf }

  /// 行の横位置を覚える入れ物。
  var lineStops: LineStopsCache { fieldStops ?? surface.lineStops }

  /// タブの刻み（pt）。
  var tabWidth: CGFloat {
    guard let field else { return surface.config.tabWidth(columns: surface.indentation.unit) }
    return CGFloat(Indentation.fallback.unit) * Self.spaceWidth(field.style.font)
  }

  /// 編集の規則が読む環境。入力欄はページ送りが 1 行で、縦の並びに差し込みは無い。
  func editingEnvironment() -> EditingEnvironment? {
    guard let text = currentContent?.text else { return nil }
    let geometry = ShapedLineGeometry(text: text, cache: lineStops, tabWidth: tabWidth)
    guard let field else {
      let config = surface.config
      let lines = Int(
        (Double(surface.size.height - config.topInset) / Double(config.lineHeight)).rounded(.down))
      return EditingEnvironment(
        text: text, geometry: geometry, pageLines: max(1, lines - 2), rows: surface.rows,
        indentation: surface.indentation, lineBreak: surface.lineBreak,
        killBuffer: KillBuffer.contents)
    }
    return EditingEnvironment(
      text: text, geometry: geometry, pageLines: 1,
      rows: RowLayout(lineHeight: Double(field.style.lineHeight)), indentation: .fallback,
      lineBreak: .lf, killBuffer: KillBuffer.contents)
  }

  /// 編集の束を 1 回で文の出どころへ渡し、戻ったら写しを引く（取引の中だけ）。束を当てた後の文を返す（結ばれていなければ
  /// nil）。本文の場の編集だけが、縦の並びの差し込みの境をずらす。
  func deliver(_ batch: EditBatch) -> TextRope? {
    precondition(change != nil, "場の文の変化は取引の中でだけ渡す")
    guard let before = currentContent?.text else { return nil }
    source.apply(batch.edits)
    guard let content = source.content else { return nil }
    change?.content = content
    change?.edited = true
    guard isBody else { return content.text }
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

  /// 選択の地・キャレット・変換中の文字（`focused` はこの場が主で面に焦点があるか）。変換中は、変換に入った各カーソルの
  /// キャレットが IME の注目位置（主の注目位置と同じ相対位置。文節を選んでいる間は無し）。
  func caretMaterial(focused: Bool, blinks: Bool) -> CaretMaterial {
    let all = editor.state.cursors.all
    let selections = all.map(\.selection).filter { $0.length > 0 }.sorted {
      $0.location < $1.location
    }
    let collapsed = all.filter { $0.selection.length == 0 }.map(\.position).sorted()
    guard let composition = editor.composition else {
      return CaretMaterial(
        selections: selections, carets: all.map(\.position).sorted(), collapsed: collapsed,
        epoch: CACurrentMediaTime(), focused: focused, blinks: blinks)
    }
    let attention = composition.selection
    let offset = attention.location - composition.range.location
    let carets = all.indices.compactMap { index -> Int? in
      guard index < composition.marked.count, let marked = composition.marked[index] else {
        return all[index].position
      }
      return attention.length == 0 ? marked.location + offset : nil
    }
    return CaretMaterial(
      selections: selections, carets: carets.sorted(), collapsed: collapsed,
      epoch: CACurrentMediaTime(), focused: focused, blinks: blinks,
      marked: MarkedMaterial(
        ranges: composition.marked.compactMap { $0 }.sorted { $0.location < $1.location },
        appearance: composition.appearance))
  }

  private static func spaceWidth(_ font: NSFont) -> CGFloat {
    var space: UniChar = 0x20
    var glyph: CGGlyph = 0
    CTFontGetGlyphsForCharacters(font as CTFont, &space, &glyph, 1)
    var advance = CGSize.zero
    CTFontGetAdvancesForGlyphs(font as CTFont, .horizontal, &glyph, &advance, 1)
    return advance.width
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
  /// 取引の中で渡した編集で、組版の変わった行（当てた順。本文の場だけ）。
  var rowEdits: [RowEdit] = []
  /// 文を変えたか。
  var edited = false
  /// カーソルの列を ⌘U で戻した。
  var restoresCursors = false
  /// 最も長い行を測り直す（本文の丸ごと置き換え）。
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
