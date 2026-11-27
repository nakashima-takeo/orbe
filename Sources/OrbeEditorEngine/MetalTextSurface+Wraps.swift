import AppKit
import OrbeEditorCore

/// 行ごとの折り返し——表示の構成が折り返す構成で、本文の UTF-8 のバイト数が上限以下なら、全部の行の折り返しを main が同期で計算し、
/// 縦の並びに載せる。全部を計算し直すのは、取引の確定で本文の版・折り返しの幅・タブの刻みのどれかが、載せた折り返しと
/// 違うとき（文書と結んだ・本文を丸ごと置き換えた・大きさや行番号の列の桁や表示の構成が変わった・字下げの作法が変わった）。
/// 面自身の編集は、変わった行だけを、その取引の中で計算し直す。
extension MetalTextSurface {
  /// 折り返す本文の大きさの上限（UTF-8 のバイト数）。全部の行を計算し直す 1 回が 1 コマ（16ms）に収まる大きさ。字の数で
  /// なくバイト数で数えるのは、折り返しの字 1 つあたりの手間が和文の字で重く、バイト数の方が字の数より手間に近い物差しだから
  /// （手間は揃わない——同じバイト数で、和文の Markdown は ASCII の Swift の約 1.8 倍かかる）。
  static let wrapLimit = 2_400_000

  /// 本文 `text` を折り返すか——表示の構成が折り返す構成で、本文の UTF-8 のバイト数が上限以下。
  func wraps(_ text: TextRope) -> Bool {
    presentation.wraps && text.utf8Length <= Self.wrapLimit
  }

  /// 折り返しの幅（本文の区画の幅から半角 1 字ぶんを引いた幅。区画が幅を持たなければ nil）。
  func wrapWidth(lineCount: Int) -> Double? {
    let text = config.layout(size: size, lineCount: lineCount, rows: rows, arrangement: arrangement)
      .text
    guard text.width > 0, text.height > 0 else { return nil }
    return Double(text.width - config.cell)
  }

  /// 折り返しの寸法。「ほか N 字」の幅も、本文と同じく字ごとの幅の和で出す（打鍵のたびに N が変わる行で、印を組まない）。
  func wrapMetrics(width: Double, tabWidth: Double) -> LineWrap.Metrics {
    let config = config
    return LineWrap.Metrics(
      font: config.font, width: CGFloat(width), tabWidth: CGFloat(tabWidth), ascii: asciiWidths
    ) { omitted in
      let units = ContiguousArray(config.omittedLabel(omitted).utf16)
      let glyphs = GlyphFonts.glyphs(units, font: config.font)
      return config.cell + units.indices.reduce(0) { $0 + (glyphs.width(at: $1) ?? 0) }
    }
  }

  /// 取引の確定で、行ごとの折り返しを、写し `content` の本文と今の幅・タブの刻みに揃える。全部の行を計算し直して置いたか、
  /// 折り返しを外したら、その前の縦の並びを返す。
  func settleWraps(_ content: SurfaceContent?) -> RowLayout? {
    guard let content else { return nil }
    let text = content.text
    let tabWidth = Double(config.tabWidth(columns: indentation.unit))
    guard wraps(text), let width = wrapWidth(lineCount: text.lineCount) else {
      guard rows.wraps != nil else { return nil }
      let before = rows
      rows.setWraps(nil)
      return before
    }
    if let current = rows.wraps, current.width == width, current.tabWidth == tabWidth,
      current.lineCount == text.lineCount, current.version == content.version
    {
      return nil
    }
    let before = rows
    let metrics = wrapMetrics(width: width, tabWidth: tabWidth)
    rows.setWraps(
      LineWraps(
        width: width, tabWidth: tabWidth, version: content.version,
        lines: LineWrap.wrap(rows: 0..<text.lineCount, in: text, metrics)))
    return before
  }

  /// 面自身の編集の束を当てた後の写し `content` で、折り返しを待つ行 `unwrapped`（`RowLayout.shift` が返したもの）を
  /// 折り返し直す。
  func rewrapEdited(_ content: SurfaceContent, _ unwrapped: RowLayout.Unwrapped) {
    guard let wraps = rows.wraps else { return }
    let text = content.text
    let metrics = wrapMetrics(width: wraps.width, tabWidth: wraps.tabWidth)
    rows.rewrap(unwrapped, version: content.version) {
      LineWrap.wrap(rows: $0, in: text, metrics, resuming: $1)
    }
  }
}
