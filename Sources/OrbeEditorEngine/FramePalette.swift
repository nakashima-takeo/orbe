import AppKit
import OrbeEditorCore

/// 色 1 つ（面の色空間の値、α は乗算していない）。
struct FrameColor: Equatable, Sendable {
  var packed: UInt32

  /// 透明。
  static let clear = FrameColor(packed: 0)

  init(packed: UInt32) {
    self.packed = packed
  }

  /// `color` を外観 `appearance` で面の色空間 `space` に解く。
  @MainActor
  init(_ color: NSColor, appearance: NSAppearance, space: CGColorSpace) {
    self.init(components: Self.components(color, appearance: appearance, space: space))
  }

  fileprivate init(components: [Float]) {
    packed = components.enumerated().reduce(UInt32(0)) {
      $0 | UInt32(($1.element * 255).rounded()) << (8 * UInt32($1.offset))
    }
  }

  /// `color` を外観 `appearance` で面の色空間 `space` に解いた成分（RGBA、0…1）。
  @MainActor
  fileprivate static func components(
    _ color: NSColor, appearance: NSAppearance, space: CGColorSpace
  ) -> [Float] {
    var resolved = color
    appearance.performAsCurrentDrawingAppearance {
      resolved = NSColorSpace(cgColorSpace: space).flatMap { color.usingColorSpace($0) } ?? color
    }
    return [
      resolved.redComponent, resolved.greenComponent, resolved.blueComponent,
      resolved.alphaComponent,
    ].map { Float(min(max($0, 0), 1)) }
  }
}

/// 字のインクの色——色と、それで描く字の太らせの段（Core Graphics の font smoothing 相当。字の色の明るさ・色空間・
/// 倍率で決まる）。
struct InkColor: Equatable, Sendable {
  var color: FrameColor
  var dilation: Int

  /// `color` を外観 `appearance` で面の色空間 `space` に解き、倍率 `scale` で描く字の太らせの段を決める。
  @MainActor
  init(_ color: NSColor, appearance: NSAppearance, space: CGColorSpace, scale: CGFloat) {
    let components = FrameColor.components(color, appearance: appearance, space: space)
    self.color = FrameColor(components: components)
    dilation = DilationProbe.level(
      red: components[0], green: components[1], blue: components[2], space: space, scale: scale)
  }
}

/// 面の外観で解いた色の組。外観か倍率が変われば main が解き直して置く。
struct FramePalette: Equatable, Sendable {
  var text: InkColor
  /// 役割の字の色（`SyntaxRole` の番号で引く。色の無い役割は本文の色）。
  var roles: [InkColor]
  var gutterText: InkColor
  var added: FrameColor
  var modified: FrameColor
  var removed: FrameColor
  var caret: FrameColor
  var selection: FrameColor
  var inactiveSelection: FrameColor
  /// 変換中の文字の見た目（OS の文字入力の見た目で、見え方の契約には出さない）——IME が選んでいない文節の下線と、属性の
  /// 無い未確定の文字の地（NSTextView の既定の `markedTextAttributes`）。IME が選んでいる文節の下線は本文の色。
  var markedUnderline: FrameColor
  var markedBackground: FrameColor
  var whitespace: FrameColor
  var findMatch: FrameColor
  var currentFindMatch: FrameColor
  var currentFindLine: FrameColor
  var selectionOccurrence: FrameColor
  var selectionOccurrenceInactive: FrameColor
  var wordOccurrence: FrameColor
  var overview: OverviewPalette
  /// 行の型（表示の構成の `lineStyles` の番号で引く）。
  var lineStyles: [LineInk]

  /// 役割 `role` の字の色（役割が無ければ本文の色）。
  func ink(_ role: SyntaxRole?) -> InkColor { role.map { roles[$0.rawValue] } ?? text }

  /// 行の型 `style` の色（型が無いか、構成の型の外を指していれば nil）。
  func lineStyle(_ style: Int?) -> LineInk? {
    guard let style, lineStyles.indices.contains(style) else { return nil }
    return lineStyles[style]
  }

  /// NSTextView の既定の未確定の地（外観で解く動的な色）。
  @MainActor private static let markedBackgroundColor =
    NSTextView().markedTextAttributes?[.backgroundColor] as? NSColor ?? .systemYellow

  @MainActor
  init(
    style: TextSurfaceStyle, lineStyles: [LineStyle], appearance: NSAppearance,
    space: CGColorSpace, scale: CGFloat
  ) {
    let resolve = { FrameColor($0, appearance: appearance, space: space) }
    let ink = { InkColor($0, appearance: appearance, space: space, scale: scale) }
    text = ink(style.textColor)
    caret = resolve(style.caretColor)
    selection = resolve(style.selectionColor)
    inactiveSelection = resolve(style.inactiveSelectionColor)
    let text = text
    roles = SyntaxRole.allCases.map { style.roleColors[$0].map(ink) ?? text }
    gutterText = ink(style.gutterTextColor)
    added = resolve(style.marks.added)
    modified = resolve(style.marks.modified)
    removed = resolve(style.marks.removed)
    markedUnderline = resolve(.tertiaryLabelColor)
    markedBackground = resolve(Self.markedBackgroundColor)
    whitespace = resolve(style.decorations.whitespaceColor)
    findMatch = resolve(style.highlights.findMatch)
    currentFindMatch = resolve(style.highlights.currentFindMatch)
    currentFindLine = resolve(style.highlights.currentFindLine)
    selectionOccurrence = resolve(style.highlights.selectionOccurrence)
    selectionOccurrenceInactive = resolve(style.highlights.selectionOccurrenceInactive)
    wordOccurrence = resolve(style.highlights.wordOccurrence)
    overview = OverviewPalette(style.overview, appearance: appearance, space: space)
    let gutterText = gutterText
    self.lineStyles = lineStyles.map { line in
      LineInk(
        background: line.background.map(resolve), text: line.text.map(ink), sign: line.sign,
        signInk: line.signColor.map(ink) ?? gutterText)
    }
  }
}

/// 行の型を外観で解いた色——行の地・字の色（あれば構文の色に代わる）・記号の字とその色。
struct LineInk: Equatable, Sendable {
  var background: FrameColor?
  var text: InkColor?
  var sign: String?
  var signInk: InkColor
}

/// 俯瞰の色。α を半分にした色は、ミニマップの行の薄い地。
struct OverviewPalette: Equatable, Sendable {
  /// 外観が暗いか（ミニマップの字の明るさの係数）。
  var dark: Bool
  var minimapSlider: FrameColor
  var minimapSliderHover: FrameColor
  var minimapSliderActive: FrameColor
  var minimapSelection: FrameColor
  var minimapSelectionRow: FrameColor
  var minimapFind: FrameColor
  var minimapFindRow: FrameColor
  var minimapWord: FrameColor
  var minimapWordRow: FrameColor
  var minimapAdded: FrameColor
  var minimapModified: FrameColor
  var minimapRemoved: FrameColor
  var slider: FrameColor
  var sliderHover: FrameColor
  var sliderActive: FrameColor
  var border: FrameColor
  var rulerFind: FrameColor
  var rulerWord: FrameColor
  var rulerAdded: FrameColor
  var rulerModified: FrameColor
  var rulerRemoved: FrameColor
  var rulerCaret: FrameColor
  var topShadow: FrameColor
  var minimapShadow: FrameColor

  @MainActor
  init(_ style: TextSurfaceStyle.Overview, appearance: NSAppearance, space: CGColorSpace) {
    let resolve = { FrameColor($0, appearance: appearance, space: space) }
    let half = { (color: NSColor) -> FrameColor in
      var alpha: CGFloat = 1
      appearance.performAsCurrentDrawingAppearance {
        alpha = (color.usingColorSpace(.sRGB) ?? color).alphaComponent
      }
      return resolve(color.withAlphaComponent(alpha * 0.5))
    }
    dark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    let minimap = style.minimap
    minimapSlider = resolve(minimap.slider)
    minimapSliderHover = resolve(minimap.sliderHover)
    minimapSliderActive = resolve(minimap.sliderActive)
    minimapSelection = resolve(minimap.selection)
    minimapSelectionRow = half(minimap.selection)
    minimapFind = resolve(minimap.findMatch)
    minimapFindRow = half(minimap.findMatch)
    minimapWord = resolve(minimap.wordOccurrence)
    minimapWordRow = half(minimap.wordOccurrence)
    minimapAdded = resolve(minimap.added)
    minimapModified = resolve(minimap.modified)
    minimapRemoved = resolve(minimap.removed)
    let scrollbar = style.scrollbar
    slider = resolve(scrollbar.slider)
    sliderHover = resolve(scrollbar.sliderHover)
    sliderActive = resolve(scrollbar.sliderActive)
    border = resolve(scrollbar.border)
    rulerFind = resolve(scrollbar.findMatch)
    rulerWord = resolve(scrollbar.wordOccurrence)
    rulerAdded = resolve(scrollbar.added)
    rulerModified = resolve(scrollbar.modified)
    rulerRemoved = resolve(scrollbar.removed)
    rulerCaret = resolve(scrollbar.caret)
    topShadow = resolve(style.topShadow)
    minimapShadow = resolve(style.minimapShadow)
  }
}
