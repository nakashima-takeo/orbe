import AppKit
import CoreText
import OrbeEditorCore
import os

/// 色 1 つ（sRGB、α は乗算していない）と、それで描く字の太らせの段。
struct FrameColor: Equatable, Sendable {
  var packed: UInt32
  var dilation: Int

  /// `color` を外観 `appearance` で sRGB に解く。
  @MainActor
  init(_ color: NSColor, appearance: NSAppearance, fontSmoothing: Bool) {
    var resolved = color
    appearance.performAsCurrentDrawingAppearance {
      resolved = color.usingColorSpace(.sRGB) ?? color
    }
    let components = [
      resolved.redComponent, resolved.greenComponent, resolved.blueComponent,
      resolved.alphaComponent,
    ].map { Float(min(max($0, 0), 1)) }
    packed = components.enumerated().reduce(UInt32(0)) {
      $0 | UInt32(($1.element * 255).rounded()) << (8 * UInt32($1.offset))
    }
    dilation =
      fontSmoothing
      ? DilationProbe.level(red: components[0], green: components[1], blue: components[2]) : 0
  }

  init(packed: UInt32, dilation: Int) {
    self.packed = packed
    self.dilation = dilation
  }
}

/// 面の外観で解いた色の組。外観が変われば main が解き直して置く。
struct FramePalette: Equatable, Sendable {
  var text: FrameColor
  var roles: [SyntaxRole: FrameColor]
  var gutterText: FrameColor
  var added: FrameColor
  var modified: FrameColor
  var removed: FrameColor

  @MainActor
  init(style: TextSurfaceStyle, appearance: NSAppearance, fontSmoothing: Bool) {
    let resolve = { FrameColor($0, appearance: appearance, fontSmoothing: fontSmoothing) }
    text = resolve(style.textColor)
    roles = style.roleColors.mapValues(resolve)
    gutterText = resolve(style.gutterTextColor)
    added = resolve(style.marks.added)
    modified = resolve(style.marks.modified)
    removed = resolve(style.marks.removed)
  }
}

/// 行の印（git ガター）を行に写したもの。面が印を受け取ったときに、引いた写しで写す。
struct RowMarks: Equatable, Sendable {
  struct Bar: Equatable, Sendable {
    var rows: ClosedRange<Int>
    var kind: LineMarks.Kind
  }

  /// 削除の三角。`atBottom` は行の下端（改行で終わらない本文の末尾）、そうでなければ行の上端。
  struct Deletion: Equatable, Sendable {
    var row: Int
    var atBottom: Bool
  }

  var bars: [Bar] = []
  var deletions: [Deletion] = []

  static let empty = RowMarks()

  init() {}

  /// 区間は改行込みなので、最後の行は区間の最後の字の行。境は次の行の行頭（本文が改行で終わらない末尾なら最後の行の下端）。
  init(_ spans: LineMarkSpans, in text: TextRope) {
    bars = spans.marks.map { mark in
      let rows = text.rows(of: NSRange(location: mark.range.location, length: mark.range.length))
      return Bar(rows: rows, kind: mark.kind)
    }
    deletions = spans.deletions.map { offset in
      let row = text.row(containing: offset)
      return Deletion(row: row, atBottom: text.lineStart(row) != offset)
    }
  }
}

/// 面を作るときに決まり、閉じるまで変わらない見え方。フォントは不変で、Core Text はスレッドをまたいだ利用を保証する。
struct SurfaceConfig: @unchecked Sendable {
  struct Marks: Sendable {
    var gutterWidth: CGFloat
    var barWidth: CGFloat
    var barInset: CGFloat
    var barRadius: CGFloat
    var triangleSize: CGFloat
  }

  let font: CTFont
  let gutterFont: CTFont
  let lineHeight: CGFloat
  let topInset: CGFloat
  let gutterWidth: CGFloat
  let gutterTrailingInset: CGFloat
  let marks: Marks
  let fontSmoothing: Bool
  /// 打ち切った行の末尾に出す印の文言（打ち切った単位の数から）。
  let omittedLabel: @Sendable (Int) -> String
  /// 1 桁の幅（空白の送り）。
  let cell: CGFloat
  let ascent: CGFloat
  let descent: CGFloat
  let gutterAscent: CGFloat
  let gutterDescent: CGFloat
  /// 行番号の数字 0…9 のグリフと送り。
  let digitGlyphs: [CGGlyph]
  let digitAdvances: [CGFloat]

  init(
    style: TextSurfaceStyle, fontSmoothing: Bool, omittedLabel: @escaping @Sendable (Int) -> String
  ) {
    font = style.font as CTFont
    gutterFont = style.gutterFont as CTFont
    lineHeight = style.lineHeight
    topInset = style.topInset
    gutterWidth = style.gutterWidth
    gutterTrailingInset = style.gutterTrailingInset
    marks = Marks(
      gutterWidth: style.marks.gutterWidth, barWidth: style.marks.barWidth,
      barInset: style.marks.barInset, barRadius: style.marks.barRadius,
      triangleSize: style.marks.triangleSize)
    self.fontSmoothing = fontSmoothing
    self.omittedLabel = omittedLabel
    cell = Self.advances(of: [0x20], in: font).advances[0]
    ascent = CTFontGetAscent(font)
    descent = CTFontGetDescent(font)
    gutterAscent = CTFontGetAscent(gutterFont)
    gutterDescent = CTFontGetDescent(gutterFont)
    (digitGlyphs, digitAdvances) = Self.advances(of: Array("0123456789".utf16), in: gutterFont)
  }

  private static func advances(of characters: [UniChar], in font: CTFont) -> (
    glyphs: [CGGlyph], advances: [CGFloat]
  ) {
    var characters = characters
    var glyphs = [CGGlyph](repeating: 0, count: characters.count)
    CTFontGetGlyphsForCharacters(font, &characters, &glyphs, characters.count)
    var sizes = [CGSize](repeating: .zero, count: glyphs.count)
    CTFontGetAdvancesForGlyphs(font, .horizontal, glyphs, &sizes, glyphs.count)
    return (glyphs, sizes.map(\.width))
  }

  /// 行番号の列の幅——最小の幅か、最大の行番号が右の余白と印の列を残して収まる幅の広い方。
  func columnWidth(lineCount: Int) -> CGFloat {
    let digits = ceil(numberWidth(max(1, lineCount)))
    return max(gutterWidth + marks.gutterWidth, digits + gutterTrailingInset + marks.gutterWidth)
  }

  /// 行番号の数字の幅。
  func numberWidth(_ number: Int) -> CGFloat {
    var n = number
    var width: CGFloat = 0
    repeat {
      width += digitAdvances[n % 10]
      n /= 10
    } while n > 0
    return width
  }

  /// タブの刻み（pt）。
  func tabWidth(columns: Int) -> CGFloat { CGFloat(columns) * cell }

  /// 行の上端から基線まで（行の中で字を縦の中央に置く）。
  var baseline: CGFloat { (lineHeight - (ascent + descent)) / 2 + ascent }
}

/// 描く材料。main が置き、描画スレッドが表示の刻みごとに最新を読む。
struct FrameMaterial: Sendable {
  var content: SurfaceContent?
  var marks = RowMarks.empty
  var palette: FramePalette?
  var tabColumns = IndentUnit.fallback
  /// 面の大きさ（pt）と倍率。
  var size = CGSize.zero
  var scale: CGFloat = 2
  /// 面が画面に見えているか（窓にあり、隠れておらず、窓が覆われていない）。
  var visible = false
  /// 何かが変わるたびに進む。
  var revision = 0
}

/// 描く材料の箱。鍵の中では値の読み書きだけをする。
final class MaterialBox: Sendable {
  private let state = OSAllocatedUnfairLock(initialState: FrameMaterial())

  func update(_ body: @Sendable (inout FrameMaterial) -> Void) {
    state.withLock {
      body(&$0)
      $0.revision += 1
    }
  }

  func read() -> FrameMaterial { state.withLock { $0 } }

  /// 中身を空にする（面を閉じたとき描画スレッドで呼び、写しの最後の解放をそこで行う）。
  func clear() -> FrameMaterial {
    state.withLock {
      let old = $0
      $0 = FrameMaterial()
      return old
    }
  }
}
