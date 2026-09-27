import AppKit

/// 検索結果の行を描く色。動的な色を行ごと・字ごとに解かず、外観（ライト・ダーク）ごとに 1 度だけ解いて使い回す。
struct SearchRowColors {
  let primary: CGColor
  let secondary: CGColor
  let muted: CGColor
  let tertiary: CGColor
  let selection: CGColor
  let hit: CGColor
  let countFill: CGColor
  private let chips: [FileChip.Hue?: (text: CGColor, ground: CGColor)]

  @MainActor private static var resolved: [Bool: SearchRowColors] = [:]

  @MainActor static func of(_ appearance: NSAppearance) -> SearchRowColors {
    let dark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    if let colors = resolved[dark] { return colors }
    var colors: SearchRowColors?
    appearance.performAsCurrentDrawingAppearance { colors = SearchRowColors() }
    resolved[dark] = colors
    return colors!
  }

  private init() {
    primary = Theme.Color.textPrimary.cgColor
    secondary = Theme.Color.textSecondary.cgColor
    muted = Theme.Color.textMuted.cgColor
    tertiary = Theme.Color.editorTertiary.cgColor
    selection = Theme.Color.selectionFill.cgColor
    hit = Theme.Color.editorModified.withAlphaComponent(0.30).cgColor
    countFill = EditorStyle.fill(0.10).cgColor
    let hues: [FileChip.Hue] = [.orange, .blue, .yellow, .sky, .violet, .cyan, .red, .green, .teal]
    var chips: [FileChip.Hue?: (text: CGColor, ground: CGColor)] = [
      nil: (primary, EditorStyle.fill(FileChipView.groundAlpha).cgColor)
    ]
    for hue in hues {
      chips[hue] = (
        hue.color.cgColor, hue.color.withAlphaComponent(FileChipView.groundAlpha).cgColor
      )
    }
    self.chips = chips
  }

  /// 種別チップの字と地（色相が無ければ主文字と淡い塗り）。
  func chip(_ hue: FileChip.Hue?) -> (text: CGColor, ground: CGColor) {
    chips[hue] ?? chips[nil]!
  }
}
