import CoreText
import Foundation

/// 行を組んだ結果をアトラスの言葉（フォントの番号・グリフ・x）に写したもの。色は入れない——描くときに役割から引くので、
/// 役割が届いても組み直さない。
struct LaidOutLine {
  var fonts: [UInt16] = []
  var glyphs: [CGGlyph] = []
  /// 行頭からの x（pt）。
  var xs: [Float] = []
  /// 元の行の UTF-16 の位置。
  var offsets: [Int32] = []
  var width: CGFloat = 0
  /// 打ち切って描かない単位の数と、行末に出す印（打ち切っていなければ nil）。
  var omitted = 0
  var omittedMark: OmittedMark?

  struct OmittedMark {
    var fonts: [UInt16]
    var glyphs: [CGGlyph]
    var xs: [Float]
    var width: CGFloat
  }

  init() {}

  init(_ shaped: ShapedLine, fonts registry: FontRegistry) {
    for run in shaped.runs {
      let font = registry.id(run.font)
      fonts.append(contentsOf: repeatElement(font, count: run.glyphs.count))
      glyphs.append(contentsOf: run.glyphs)
      xs.append(contentsOf: run.xs.map(Float.init))
      offsets.append(contentsOf: run.offsets.map { Int32($0) })
    }
    width = shaped.width
    omitted = shaped.omitted
  }
}

/// 描画スレッドの行の組版のキャッシュ（面ごと）。鍵は行の中身とタブの桁（フォントは面ごとに固定）。上限を越えたら、
/// 古く使われたものから半分を捨てる。
final class LineLayoutCache {
  private struct Key: Hashable {
    let source: LineShaper.Source
    let tabColumns: Int
  }

  private struct Entry {
    let line: LaidOutLine
    var used: UInt64
  }

  static let capacity = 4096

  private var entries: [Key: Entry] = [:]
  private var clock: UInt64 = 0

  var count: Int { entries.count }

  func line(
    _ source: LineShaper.Source, tabColumns: Int, config: SurfaceConfig, fonts: FontRegistry
  ) -> LaidOutLine {
    clock += 1
    let key = Key(source: source, tabColumns: tabColumns)
    if let entry = entries[key] {
      entries[key]?.used = clock
      return entry.line
    }
    var line = LaidOutLine(
      LineShaper.shape(source, font: config.font, tabWidth: config.tabWidth(columns: tabColumns)),
      fonts: fonts)
    if line.omitted > 0 {
      let mark = LaidOutLine(
        LineShaper.shape(config.omittedLabel(line.omitted), font: config.font), fonts: fonts)
      line.omittedMark = LaidOutLine.OmittedMark(
        fonts: mark.fonts, glyphs: mark.glyphs, xs: mark.xs, width: mark.width)
    }
    if entries.count >= Self.capacity { evict() }
    entries[key] = Entry(line: line, used: clock)
    return line
  }

  func removeAll() { entries.removeAll() }

  private func evict() {
    let cut = entries.values.map(\.used).sorted()[entries.count / 2]
    entries = entries.filter { $0.value.used > cut }
  }
}
