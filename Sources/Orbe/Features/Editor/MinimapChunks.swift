import AppKit
import OrbeEditorCore

/// ミニマップの字——64 行のチャンクごとに、字形を合成した画像を覚えて返す。画像は構文の色で組むか、字の形だけを素の
/// 文字色で組むか（役割を問い合わせない分だけ速い——スクロールで新しく見えたチャンクを先に出し、止まってから色付きへ
/// 差し替える）。窓に新しく入ったチャンクだけ組み、本文が変われば編集の行と役割が変わった区間のチャンクを捨て、行が増減
/// したときだけ編集の行より後ろも捨てる（1MB の文書で打鍵ごとに窓ぶんを組み直さない）。覚える数には上限があり、超えたら
/// 最も長く使っていないものから捨てる（文書を端から端まで通しても、ファイルの大きさに比例して画像が溜まらない）。倍率・
/// 外観・幅・インデント単位が変われば全部捨てる。
@MainActor
final class MinimapChunks {
  static let lines = 64
  /// 覚えるチャンクの数の上限。4096 行ぶんで、近くを行き来するドラッグは描き直しなしで済む（これより増やしても速く
  /// ならなかった）。画像は 1 つ最大 240 × 256 デバイス px（幅 120pt・2x）の RGBA で 240KiB、上限で約 15MiB。窓に入る
  /// チャンクは高さ 128pt ごとに 1 つなので、1 回の描画のチャンクがこれを超えることはない。
  static let capacity = 64

  /// 描く先の条件（変われば覚えた画像は使えない）。
  struct Canvas: Equatable {
    /// 幅（デバイス px）と倍率。
    let width: Int
    let scale: Int
    let dark: Bool
    let appearance: NSAppearance

    static func == (lhs: Canvas, rhs: Canvas) -> Bool {
      lhs.width == rhs.width && lhs.scale == rhs.scale && lhs.dark == rhs.dark
    }
  }

  /// 覚えた画像と、構文の色で組んだか、最後に使った順番（大きいほど新しい）。
  private struct Entry {
    let image: CGImage
    let colored: Bool
    var lastUse: Int
  }

  private let style: MinimapStyle
  private var images: [Int: Entry] = [:]
  private var uses = 0
  private var lineCount = 0
  private var canvas: Canvas?
  private var indentUnit = 0
  private var sheet: MinimapCharSheet?

  init(style: MinimapStyle) {
    self.style = style
  }

  var cached: Set<Int> { Set(images.keys) }
  /// 素の文字色で組んだまま覚えているチャンク。
  var plain: Set<Int> { Set(images.filter { !$0.value.colored }.keys) }

  /// 文書を結び直した。
  func reset(lineCount: Int) {
    images.removeAll()
    self.lineCount = lineCount
  }

  /// 本文が変わった。
  func textDidChange(_ change: TextChange, index: LineIndex) {
    let editLine = index.point(at: change.edit.range.location).row
    if index.lineCount != lineCount {
      lineCount = index.lineCount
      let first = editLine / Self.lines
      images = images.filter { $0.key < first }
    }
    drop(covering: change.edit.newRange, index: index)
    for range in change.changedRoles.rangeView {
      drop(covering: NSRange(range), index: index)
    }
  }

  private func drop(covering range: NSRange, index: LineIndex) {
    let first = index.point(at: range.location).row / Self.lines
    let last = index.point(at: max(range.location, NSMaxRange(range) - 1)).row / Self.lines
    for chunk in first...last { images[chunk] = nil }
  }

  /// 覚えているか（素の色のままでも）。
  func contains(_ chunk: Int) -> Bool { images[chunk] != nil }

  /// チャンクの画像。覚えていればそれ（素の色のままでも）を、無ければ `colored` の組み方で組んで覚える。
  func image(_ chunk: Int, document: EditorDocument, canvas: Canvas, colored: Bool) -> CGImage? {
    if canvas != self.canvas || document.indentUnit != indentUnit {
      images.removeAll()
      if canvas.scale != self.canvas?.scale { sheet = nil }
      self.canvas = canvas
      indentUnit = document.indentUnit
    }
    uses += 1
    if let entry = images[chunk] {
      images[chunk]?.lastUse = uses
      return entry.image
    }
    guard let image = render(chunk, document: document, canvas: canvas, colored: colored) else {
      return nil
    }
    if images.count >= Self.capacity,
      let oldest = images.min(by: { $0.value.lastUse < $1.value.lastUse })?.key
    {
      images[oldest] = nil
    }
    images[chunk] = Entry(image: image, colored: colored, lastUse: uses)
    return image
  }

  /// `chunks` のうち素の色で覚えている最小のチャンクを、組んだときと同じ条件（`canvas`）で構文の色へ組み直す。組み直した
  /// ら true。条件は今のビューから取らない——窓から外れている間は倍率や幅が変わって見え、戻っても素の色が残る。
  func colorFirstPlain(in chunks: ClosedRange<Int>, document: EditorDocument) -> Bool {
    guard let canvas,
      let chunk = images.filter({ chunks.contains($0.key) && !$0.value.colored }).keys.min(),
      let entry = images[chunk],
      let image = render(chunk, document: document, canvas: canvas, colored: true)
    else { return false }
    images[chunk] = Entry(image: image, colored: true, lastUse: entry.lastUse)
    return true
  }

  /// チャンクの字を premultiplied RGBA に合成する。色は役割の色（無ければ・`colored` でなければ素の文字色）、α は字形の
  /// 明度 × 明るさの係数。
  private func render(_ chunk: Int, document: EditorDocument, canvas: Canvas, colored: Bool)
    -> CGImage?
  {
    let index = document.lineIndex
    let firstRow = chunk * Self.lines
    guard firstRow < index.lineCount else { return nil }
    let rows = firstRow..<min(firstRow + Self.lines, index.lineCount)
    let start = index.start(ofRow: rows.lowerBound)
    let range = NSRange(location: start, length: index.end(ofRow: rows.upperBound - 1) - start)
    let units = Array(document.surface.substring(in: range).utf16)
    let roles = colored ? document.roleSpans(in: range) : []
    let scale = canvas.scale
    let sheet = self.sheet ?? MinimapCharSheet(scale: scale, font: Theme.Typography.editorCode)
    self.sheet = sheet
    let width = max(1, canvas.width)
    let lineHeight = sheet.glyphHeight
    let height = Self.lines * lineHeight
    let columns = MinimapLine.columns(canvasWidth: canvas.width, scale: scale)
    let colors = resolvedColors(canvas.appearance)
    let ratio = canvas.dark ? style.darkGlyphRatio : style.lightGlyphRatio
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    var roleIndex = 0
    for row in rows {
      let lineStart = index.start(ofRow: row)
      var end = min(index.end(ofRow: row), start + units.count) - start
      let from = lineStart - start
      if end > from, units[end - 1] == 0x0A { end -= 1 }
      if end > from, units[end - 1] == 0x0D { end -= 1 }
      while roleIndex < roles.count, NSMaxRange(roles[roleIndex].range) <= lineStart {
        roleIndex += 1
      }
      let cells = MinimapLine.cells(
        units[from..<end], lineStart: lineStart, roles: roles[roleIndex...],
        tabSize: document.indentUnit, columns: columns)
      let dy = (row - rows.lowerBound) * lineHeight
      for cell in cells {
        let color = cell.role.flatMap { colors[$0] } ?? colors.text
        let dx = MinimapLine.gutter + cell.column * scale
        for y in 0..<lineHeight {
          for x in 0..<sheet.glyphWidth where dx + x < width {
            let alpha = floor(Double(sheet.value(cell.glyph, x: x, y: y)) * ratio) / 255
            guard alpha > 0 else { continue }
            let offset = ((dy + y) * width + dx + x) * 4
            pixels[offset] = UInt8(color.r * alpha * 255)
            pixels[offset + 1] = UInt8(color.g * alpha * 255)
            pixels[offset + 2] = UInt8(color.b * alpha * 255)
            pixels[offset + 3] = UInt8(alpha * 255)
          }
        }
      }
    }
    guard let provider = CGDataProvider(data: Data(pixels) as CFData),
      let space = CGColorSpace(name: CGColorSpace.sRGB)
    else { return nil }
    return CGImage(
      width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
      space: space, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
      provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
  }

  private struct RGB {
    let r: Double
    let g: Double
    let b: Double
  }

  private struct Colors {
    let text: RGB
    let roles: [SyntaxRole: RGB]
    subscript(_ role: SyntaxRole) -> RGB? { roles[role] }
  }

  /// 役割の色を外観で sRGB に解く。
  private func resolvedColors(_ appearance: NSAppearance) -> Colors {
    var text = RGB(r: 1, g: 1, b: 1)
    var roles: [SyntaxRole: RGB] = [:]
    appearance.performAsCurrentDrawingAppearance {
      let rgb = { (color: NSColor) -> RGB in
        let c = color.usingColorSpace(.sRGB) ?? color
        return RGB(r: c.redComponent, g: c.greenComponent, b: c.blueComponent)
      }
      text = rgb(style.textColor)
      for (role, color) in style.roleColors { roles[role] = rgb(color) }
    }
    return Colors(text: text, roles: roles)
  }
}
