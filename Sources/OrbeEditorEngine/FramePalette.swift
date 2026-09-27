import AppKit
import OrbeEditorCore

/// 色 1 つ（面の色空間の値、α は乗算していない）と、それで描く字の太らせの段（色空間と倍率で決まる）。
struct FrameColor: Equatable, Sendable {
  var packed: UInt32
  var dilation: Int

  /// `color` を外観 `appearance` で面の色空間 `space` に解き、倍率 `scale` で描く字の太らせの段を決める。
  @MainActor
  init(
    _ color: NSColor, appearance: NSAppearance, space: CGColorSpace, fontSmoothing: Bool,
    scale: CGFloat
  ) {
    var resolved = color
    appearance.performAsCurrentDrawingAppearance {
      resolved = NSColorSpace(cgColorSpace: space).flatMap { color.usingColorSpace($0) } ?? color
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
      ? DilationProbe.level(
        red: components[0], green: components[1], blue: components[2], space: space, scale: scale)
      : 0
  }

  init(packed: UInt32, dilation: Int) {
    self.packed = packed
    self.dilation = dilation
  }

  /// 外観に依らない色（IME が指定した色）を sRGB に詰めたもの。
  static func pack(_ color: NSColor) -> UInt32 {
    let resolved = color.usingColorSpace(.sRGB) ?? color
    return [
      resolved.redComponent, resolved.greenComponent, resolved.blueComponent,
      resolved.alphaComponent,
    ].enumerated().reduce(UInt32(0)) {
      $0 | UInt32((min(max($1.element, 0), 1) * 255).rounded()) << (8 * UInt32($1.offset))
    }
  }
}

/// 面の外観で解いた色の組。外観か倍率が変われば main が解き直して置く。
struct FramePalette: Equatable, Sendable {
  var text: FrameColor
  var roles: [SyntaxRole: FrameColor]
  var gutterText: FrameColor
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
  var indentGuide: FrameColor
  var whitespace: FrameColor
  var findMatch: FrameColor
  var currentFindMatch: FrameColor
  var currentFindLine: FrameColor
  var selectionOccurrence: FrameColor
  var selectionOccurrenceInactive: FrameColor
  var wordOccurrence: FrameColor
  var overview: OverviewPalette

  /// NSTextView の既定の未確定の地（外観で解く動的な色）。
  @MainActor private static let markedBackgroundColor =
    NSTextView().markedTextAttributes?[.backgroundColor] as? NSColor ?? .systemYellow

  @MainActor
  init(
    style: TextSurfaceStyle, appearance: NSAppearance, space: CGColorSpace, fontSmoothing: Bool,
    scale: CGFloat
  ) {
    let resolve = {
      FrameColor(
        $0, appearance: appearance, space: space, fontSmoothing: fontSmoothing, scale: scale)
    }
    text = resolve(style.textColor)
    caret = resolve(style.caretColor)
    selection = resolve(style.selectionColor)
    inactiveSelection = resolve(style.inactiveSelectionColor)
    roles = style.roleColors.mapValues(resolve)
    gutterText = resolve(style.gutterTextColor)
    added = resolve(style.marks.added)
    modified = resolve(style.marks.modified)
    removed = resolve(style.marks.removed)
    markedUnderline = resolve(.tertiaryLabelColor)
    markedBackground = resolve(Self.markedBackgroundColor)
    indentGuide = resolve(style.decorations.indentGuideColor)
    whitespace = resolve(style.decorations.whitespaceColor)
    findMatch = resolve(style.highlights.findMatch)
    currentFindMatch = resolve(style.highlights.currentFindMatch)
    currentFindLine = resolve(style.highlights.currentFindLine)
    selectionOccurrence = resolve(style.highlights.selectionOccurrence)
    selectionOccurrenceInactive = resolve(style.highlights.selectionOccurrenceInactive)
    wordOccurrence = resolve(style.highlights.wordOccurrence)
    overview = OverviewPalette(style.overview, appearance: appearance, space: space)
  }
}

/// 俯瞰の色（字を描かない図形の色なので、字の太らせの段は測らない）。α を半分にした色は、ミニマップの行の薄い地。
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
    let resolve = {
      FrameColor($0, appearance: appearance, space: space, fontSmoothing: false, scale: 1)
    }
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
