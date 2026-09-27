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
  /// 打ち切って描かない単位の数と、行末に出す印（打ち切っていなければ nil）。
  var omitted = 0
  var omittedMark: OmittedMark?
  /// 行の中の位置と x の対応（キャレット・選択の地・横の「見えるところまで」が要る行だけ。要るまで作らない）。
  var carets: CaretMap?

  struct OmittedMark {
    var fonts: [UInt16]
    var glyphs: [CGGlyph]
    var xs: [Float]
    var width: CGFloat
  }

  init(_ shaped: ShapedLine, fonts registry: FontRegistry) {
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

/// 描画スレッドの行の組版のキャッシュ（面ごと）。2 段で引く。
///
/// - 前のコマで描いた行（写しの版と行 → 組んだ結果）: 定常のスクロールでは見えている行のほとんどがここで当たり、行の
///   中身を写さず・ハッシュしない。本文の編集は変わった行だけを捨て、後ろの行をずらす。版かタブの桁が知らない形で
///   変われば全部捨てる。
/// - 行の中身とタブの桁を鍵にした結果（フォントは面ごとに固定）: 編集をまたいでも同じ中身の行は組み直さない。行の数か、
///   持つ単位（行の中身とグリフ）の数が上限を越えたら、古く使われたものから半分を捨てる——長い行ばかりの文書でも覚える
///   量が行の長さに比例して膨らまない。
final class LineLayoutCache {
  private struct Key: Hashable {
    let source: LineShaper.Source
    let tabColumns: Int
  }

  private struct Entry {
    var line: LaidOutLine
    var used: UInt64
    /// 持つ単位の数（行の中身・グリフ・キャレットの位置）。
    var weight: Int
  }

  static let capacity = 4096
  static let weightBudget = 2_000_000

  private var entries: [Key: Entry] = [:]
  private var clock: UInt64 = 0
  /// 覚えている行の数と、持つ単位の数。
  var count: Int { entries.count }
  private(set) var weight = 0

  /// このコマで組版した（どちらの段にも無かった）行の数。
  private(set) var shapedInFrame = 0
  private var drawnRows: [Int: LaidOutLine] = [:]
  private var frameRows: [Int: LaidOutLine] = [:]
  private var rowsVersion: Int?
  private var rowsTabColumns: Int?

  /// 本文の編集を受け取る（前のコマで描いた行のうち、変わった行を捨てて後ろをずらす）。
  func receive(_ edits: [RowEdit]) {
    for edit in edits {
      drawnRows = Self.shifted(drawnRows, by: edit)
      rowsVersion = edit.version
    }
  }

  /// コマを組み始める。前のコマの行が版 `version`・タブの桁 `tabColumns` のものでなければ全部捨てる。
  func beginFrame(version: Int, tabColumns: Int) {
    if rowsVersion != version || rowsTabColumns != tabColumns {
      drawnRows.removeAll(keepingCapacity: true)
    }
    rowsVersion = version
    rowsTabColumns = tabColumns
    frameRows.removeAll(keepingCapacity: true)
    shapedInFrame = 0
  }

  /// このコマで描く行 `row` の組んだ結果。`carets` なら位置と x の対応も持たせる。
  func line(
    row: Int, in text: TextRope, tabColumns: Int, config: SurfaceConfig, fonts: FontRegistry,
    carets: Bool = false
  ) -> LaidOutLine {
    var laid = drawnRows[row]
    if laid == nil || (carets && laid?.carets == nil) {
      laid = line(
        LineShaper.source(row: row, in: text).source, tabColumns: tabColumns, config: config,
        fonts: fonts, carets: carets)
    }
    frameRows[row] = laid
    return laid!
  }

  /// コマを組み終えた。このコマで描いた行が、次のコマの「前のコマで描いた行」になる。
  func endFrame() {
    swap(&drawnRows, &frameRows)
    frameRows.removeAll(keepingCapacity: true)
  }

  /// 編集 `edit` の後の行へ写す（変わった行は捨て、後ろの行はずらす）。
  static func shifted<Value>(_ rows: [Int: Value], by edit: RowEdit) -> [Int: Value] {
    let delta = edit.inserted - edit.rows.count
    var result: [Int: Value] = [:]
    for (row, value) in rows {
      if row < edit.rows.lowerBound {
        result[row] = value
      } else if row >= edit.rows.upperBound {
        result[row + delta] = value
      }
    }
    return result
  }

  /// 行の中身 `source` の組んだ結果。`carets` なら位置と x の対応も持たせる（覚えた結果に無ければ組み直して足す）。
  func line(
    _ source: LineShaper.Source, tabColumns: Int, config: SurfaceConfig, fonts: FontRegistry,
    carets: Bool = false
  ) -> LaidOutLine {
    clock += 1
    let key = Key(source: source, tabColumns: tabColumns)
    let shape = {
      LineShaper.shape(source, font: config.font, tabWidth: config.tabWidth(columns: tabColumns))
    }
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
    var line = LaidOutLine(shaped, fonts: fonts)
    if carets { line.carets = shaped.carets }
    if line.omitted > 0 {
      let mark = LaidOutLine(
        LineShaper.shape(config.omittedLabel(line.omitted), font: config.font), fonts: fonts)
      line.omittedMark = LaidOutLine.OmittedMark(
        fonts: mark.fonts, glyphs: mark.glyphs, xs: mark.xs, width: mark.width)
    }
    let entry = Entry(
      line: line, used: clock,
      weight: source.head.count + line.glyphs.count + (line.carets?.count ?? 0))
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
