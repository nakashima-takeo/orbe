import CoreText
import Foundation
import OrbeEditorCore

/// 行を組んだ結果をアトラスの言葉（フォントの番号・グリフ・x）に写したもの。色は入れない——描くときに役割から引くので、
/// 役割が届いても組み直さない。
struct LaidOutLine {
  var fonts: [UInt16] = []
  var glyphs: [CGGlyph] = []
  /// 行頭からの x（pt）。
  var xs: [Float] = []
  /// 基線からの y（pt、上が正）。全部 0 の行（ほとんどの行）では空。
  var ys: [Float] = []
  /// 元の行の UTF-16 の位置。
  var offsets: [Int32] = []
  var width: CGFloat = 0
  /// 組んだ段の長さ（UTF-16。打ち切って描かない単位を含み、改行と行末の `\r` を除く。折り返さない行では行の中身の長さ
  /// ——`LineShaper.Source.length`）。
  var length: Int
  /// 打ち切って描かない単位の数と、行末に出す印（打ち切っていなければ nil）。
  var omitted = 0
  var omittedMark: OmittedMark?
  /// 行の中の位置と x の対応（キャレット・選択の地・強調の地・装備・横の「見えるところまで」が要る行だけ。要るまで
  /// 作らない）。
  var carets: CaretMap?
  /// 行の装備の素。
  var decor: LineDecor

  struct OmittedMark {
    var fonts: [UInt16] = []
    var glyphs: [CGGlyph] = []
    var xs: [Float] = []
    var width: CGFloat

    init(_ shaped: ShapedLine, fonts registry: FontRegistry) {
      for run in shaped.runs {
        fonts.append(contentsOf: repeatElement(registry.id(run.font), count: run.glyphs.count))
        glyphs.append(contentsOf: run.glyphs)
        xs.append(contentsOf: run.xs.map(Float.init))
      }
      width = shaped.width
    }
  }

  init(_ shaped: ShapedLine, length: Int, fonts registry: FontRegistry, decor: LineDecor) {
    self.length = length
    self.decor = decor
    let raised = shaped.runs.contains { $0.ys.contains { $0 != 0 } }
    for run in shaped.runs {
      let font = registry.id(run.font)
      fonts.append(contentsOf: repeatElement(font, count: run.glyphs.count))
      glyphs.append(contentsOf: run.glyphs)
      xs.append(contentsOf: run.xs.map(Float.init))
      if raised { ys.append(contentsOf: run.ys.map(Float.init)) }
      offsets.append(contentsOf: run.offsets.map { Int32($0) })
    }
    width = shaped.width
    omitted = shaped.omitted
  }
}

/// 描画スレッドの行の組版のキャッシュ（面ごと）。2 段で引く。組む単位は行の段（折り返さない行は行全体の 1 段）。
///
/// - 前のコマで描いた段（写しの版と行と段 → 組んだ結果）: 定常のスクロールでは見えている段のほとんどがここで当たり、行の
///   中身を写さず・ハッシュしない。本文の編集は変わった行の段だけを捨て、後ろの行をずらす。版かタブの桁か折り返しの幅が
///   知らない形で変われば全部捨てる。
/// - 描く単位の列（行か段の中身）とタブの桁を鍵にした結果（フォントはキャッシュごとに固定——本文は面のフォント、入力欄は
///   入力欄のフォント）: 編集をまたいでも同じ中身の段は組み直さない。装備は行の中身で決まる（段の中身だけでは決まらない）
///   ので、鍵にも結果にも入れず、引いた呼び手が置く。
///
/// 段を組む前に読む行（行の中身 → 描く単位の列と装備の素）も、行の中身を鍵に覚える（→ `read`）——段の一部だけが前の
/// コマに無い行・折り返しの幅が変わった行・差し込んだ行で、URL の検出と空白の走査を、コマごとに行全体で走らせない。どちらの
/// 表も、数か、持つ単位（行の中身とグリフ）の数が上限を越えたら、古く使われたものから半分を捨てる——長い行ばかりの文書でも
/// 覚える量が行の長さに比例して膨らまない。
final class LineLayoutCache {
  private struct Key: Hashable {
    let shown: LineShaper.Displayed
    let tabColumns: Int
  }

  private struct Entry {
    var line: LaidOutLine
    var used: UInt64
    /// 持つ単位の数（行の中身・グリフ・キャレットの位置）。
    var weight: Int
  }

  /// 前のコマで描いた段の鍵——文書の行と、行の中の段。
  struct Segment: Hashable {
    var row: Int
    var segment: Int
  }

  /// 読んだ行（→ `read`）。
  private struct Read {
    let shown: LineShaper.Displayed
    let decor: LineDecor
    var used: UInt64
    /// 持つ単位の数（行の中身・描く単位の列・装備）。
    let weight: Int
  }

  static let capacity = 4096
  static let weightBudget = 2_000_000

  private var entries: [Key: Entry] = [:]
  private var reads: [LineShaper.Source: Read] = [:]
  private var readWeight = 0
  private var clock: UInt64 = 0
  /// 覚えている段の数と、持つ単位の数。
  var count: Int { entries.count }
  private(set) var weight = 0

  /// このコマで組版した（どちらの段にも無かった）段の数と、面を結んでからの合計。
  private(set) var shapedInFrame = 0 {
    didSet { if shapedInFrame > oldValue { shapedTotal += shapedInFrame - oldValue } }
  }
  private(set) var shapedTotal = 0
  private var drawnRows: [Segment: LaidOutLine] = [:]
  private var frameRows: [Segment: LaidOutLine] = [:]
  private var rowsVersion: Int?
  private var rowsTabColumns: Int?
  private var rowsWrapWidth: Double?
  /// 全行で最も広い行の幅と、それを測った版とタブの桁。
  private struct Widest {
    let version: Int
    let tabColumns: Int
    let width: CGFloat
  }

  private var widest: Widest?
  /// 組むフォントとタブの刻み（nil なら面のフォントと、桁から面の設定で出す刻み）。
  private let face: (font: CTFont, tabWidth: CGFloat)?

  init() {
    face = nil
  }

  init(font: CTFont, tabWidth: CGFloat) {
    face = (font, tabWidth)
  }

  /// 本文の編集を受け取る（前のコマで描いた段のうち、変わった行の段を捨てて後ろをずらす）。
  func receive(_ edits: [RowEdit]) {
    for edit in edits where !edit.rolesOnly {
      drawnRows = Self.shifted(drawnRows, by: edit)
      rowsVersion = edit.version
    }
  }

  /// コマを組み始める。前のコマの段が版 `version`・タブの桁 `tabColumns`・折り返しの幅 `wrapWidth`（折り返さなければ nil）
  /// のものでなければ全部捨てる。
  func beginFrame(version: Int, tabColumns: Int, wrapWidth: Double? = nil) {
    if rowsVersion != version || rowsTabColumns != tabColumns || rowsWrapWidth != wrapWidth {
      drawnRows.removeAll(keepingCapacity: true)
    }
    rowsVersion = version
    rowsTabColumns = tabColumns
    rowsWrapWidth = wrapWidth
    frameRows.removeAll(keepingCapacity: true)
    shapedInFrame = 0
  }

  /// 版 `version` の `rows` 行のうち最も広い行の幅（pt。行 r の組んだ結果は `line(r)`）。同じ版とタブの桁の間は測った値を
  /// 返す——全行を引くのは版ごとに 1 回。
  func widestWidth(
    version: Int, tabColumns: Int, rows: Int, line: (Int) -> LaidOutLine
  ) -> CGFloat {
    if let widest, widest.version == version, widest.tabColumns == tabColumns {
      return widest.width
    }
    let width = (0..<rows).reduce(CGFloat(0)) { max($0, line($1).width) }
    widest = Widest(version: version, tabColumns: tabColumns, width: width)
    return width
  }

  /// このコマで描く行 `row` を、行全体を 1 段として組んだ結果。前のコマで描いた行に無ければ、行の中身 `source` を読んで
  /// 引く。`carets` なら位置と x の対応も持たせる。
  func line(
    row: Int, source: () -> LineShaper.Source, tabColumns: Int, config: SurfaceConfig,
    fonts: FontRegistry, carets: Bool = false
  ) -> LaidOutLine {
    let key = Segment(row: row, segment: 0)
    if let laid = drawn(key, carets: carets) { return keep(key, laid) }
    return keep(
      key, line(source(), tabColumns: tabColumns, config: config, fonts: fonts, carets: carets))
  }

  /// 前のコマで描いた段 `segment`（`carets` なら位置と x の対応を持つもの。無ければ nil）。
  func drawn(_ segment: Segment, carets: Bool) -> LaidOutLine? {
    guard let laid = drawnRows[segment], !carets || laid.carets != nil else { return nil }
    return laid
  }

  /// 段 `segment` をこのコマで描く（次のコマの「前のコマで描いた段」になる）。
  @discardableResult
  func keep(_ segment: Segment, _ laid: LaidOutLine) -> LaidOutLine {
    frameRows[segment] = laid
    return laid
  }

  /// コマを組み終えた。このコマで描いた段が、次のコマの「前のコマで描いた段」になる。
  func endFrame() {
    swap(&drawnRows, &frameRows)
    frameRows.removeAll(keepingCapacity: true)
  }

  /// 編集 `edit` の後の行へ写す（変わった行の段は捨て、後ろの行はずらす）。
  private static func shifted(_ rows: [Segment: LaidOutLine], by edit: RowEdit) -> [Segment:
    LaidOutLine]
  {
    let delta = edit.inserted - edit.rows.count
    var result: [Segment: LaidOutLine] = [:]
    for (key, value) in rows {
      if key.row < edit.rows.lowerBound {
        result[key] = value
      } else if key.row >= edit.rows.upperBound {
        result[Segment(row: key.row + delta, segment: key.segment)] = value
      }
    }
    return result
  }

  /// 行の中身 `source` を行全体の 1 段として組んだ結果と装備の素。`carets` か装備があれば、位置と x の対応も持たせる。
  func line(
    _ source: LineShaper.Source, tabColumns: Int, config: SurfaceConfig, fonts: FontRegistry,
    carets: Bool = false
  ) -> LaidOutLine {
    let found = read(source)
    var laid = line(
      found.shown, tabColumns: tabColumns, config: config, fonts: fonts,
      carets: carets || found.decor.needsCarets)
    laid.decor = found.decor
    return laid
  }

  /// 行の中身 `source` の描く単位の列と装備の素。行の中身を鍵に覚え、同じ中身の行は作り直さない。
  func read(_ source: LineShaper.Source) -> (shown: LineShaper.Displayed, decor: LineDecor) {
    clock += 1
    if let index = reads.index(forKey: source) {
      reads.values[index].used = clock
      return (reads.values[index].shown, reads.values[index].decor)
    }
    let shown = LineShaper.display(source)
    let decor = LineDecor(source)
    let entry = Read(
      shown: shown, decor: decor, used: clock,
      weight: source.head.count + shown.units.count + decor.weight)
    while !reads.isEmpty,
      reads.count >= Self.capacity || readWeight + entry.weight > Self.weightBudget
    {
      let cut = reads.values.map(\.used).sorted()[reads.count / 2]
      reads = reads.filter { $0.value.used > cut }
      readWeight = reads.values.reduce(0) { $0 + $1.weight }
    }
    reads[source] = entry
    readWeight += entry.weight
    return (shown, decor)
  }

  /// 描く単位の列 `shown`（行か段の中身）を組んだ結果（装備は空——呼び手が置く）。`carets` なら位置と x の対応も持たせる
  /// （覚えた結果に無ければ作って足す）。
  func line(
    _ shown: LineShaper.Displayed, tabColumns: Int, config: SurfaceConfig, fonts: FontRegistry,
    carets: Bool
  ) -> LaidOutLine {
    clock += 1
    let key = Key(shown: shown, tabColumns: tabColumns)
    let font = face?.font ?? config.font
    let tabWidth = face?.tabWidth ?? config.tabWidth(columns: tabColumns)
    let shape = { LineShaper.shape(shown, font: font, tabWidth: tabWidth) }
    if let index = entries.index(forKey: key) {
      entries.values[index].used = clock
      if carets, entries.values[index].line.carets == nil {
        shapedInFrame += 1
        let map = shape().carets
        entries.values[index].line.carets = map
        entries.values[index].weight += map.count
        weight += map.count
      }
      return entries.values[index].line
    }
    shapedInFrame += 1
    let shaped = shape()
    var line = LaidOutLine(
      shaped, length: shown.units.count + shown.omitted, fonts: fonts, decor: .empty)
    if carets { line.carets = shaped.carets }
    if line.omitted > 0 {
      line.omittedMark = LaidOutLine.OmittedMark(
        LineShaper.shape(config.omittedLabel(line.omitted), font: font), fonts: fonts)
    }
    let entry = Entry(
      line: line, used: clock,
      weight: shown.units.count + line.glyphs.count + (line.carets?.count ?? 0))
    while !entries.isEmpty,
      entries.count >= Self.capacity || weight + entry.weight > Self.weightBudget
    {
      evict()
    }
    entries[key] = entry
    weight += entry.weight
    return line
  }

  private func evict() {
    let cut = entries.values.map(\.used).sorted()[entries.count / 2]
    entries = entries.filter { $0.value.used > cut }
    weight = entries.values.reduce(0) { $0 + $1.weight }
  }
}
