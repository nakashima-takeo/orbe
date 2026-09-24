import AppKit
import OrbeEditorCore

/// ミニマップの字——64 行のチャンクごとに、字形を構文の色で合成した画像を覚えて返す。窓に新しく入ったチャンクだけ組み、
/// 本文が変われば編集の行と役割が変わった区間のチャンクを捨て、行が増減したときだけ編集の行より後ろも捨てる（1MB の
/// 文書で打鍵ごとに窓ぶんを組み直さない）。窓から外れたチャンクは捨てる。倍率・外観・幅・インデント単位が変われば
/// 全部捨てる。
@MainActor
final class MinimapChunks {
  static let lines = 64

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

  private let style: MinimapStyle
  private var images: [Int: CGImage] = [:]
  private var lineCount = 0
  private var canvas: Canvas?
  private var indentUnit = 0
  private var sheet: MinimapCharSheet?

  init(style: MinimapStyle) {
    self.style = style
  }

  var cached: Set<Int> { Set(images.keys) }

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

  /// 窓のチャンク（と前後 1 つ）だけを残し、外は捨てる。窓の外を持ち続けると、文書を端から端まで通したときにファイルの
  /// 大きさに比例して画像が溜まる。前後 1 つの余裕は、境目での往復で組み直しを繰り返さないため。
  func retain(_ chunks: ClosedRange<Int>) {
    let kept = (chunks.lowerBound - 1)...(chunks.upperBound + 1)
    images = images.filter { kept.contains($0.key) }
  }

  func image(_ chunk: Int, document: EditorDocument, canvas: Canvas) -> CGImage? {
    if canvas != self.canvas || document.indentUnit != indentUnit {
      images.removeAll()
      if canvas.scale != self.canvas?.scale { sheet = nil }
      self.canvas = canvas
      indentUnit = document.indentUnit
    }
    if let image = images[chunk] { return image }
    let image = render(chunk, document: document, canvas: canvas)
    images[chunk] = image
    return image
  }

  /// チャンクの字を premultiplied RGBA に合成する。色は役割の色（無ければ素の文字色）、α は字形の明度 × 明るさの係数。
  private func render(_ chunk: Int, document: EditorDocument, canvas: Canvas) -> CGImage? {
    let index = document.lineIndex
    let firstRow = chunk * Self.lines
    guard firstRow < index.lineCount else { return nil }
    let rows = firstRow..<min(firstRow + Self.lines, index.lineCount)
    let start = index.start(ofRow: rows.lowerBound)
    let range = NSRange(location: start, length: index.end(ofRow: rows.upperBound - 1) - start)
    let units = Array(document.surface.substring(in: range).utf16)
    let roles = document.roleSpans(in: range)
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
