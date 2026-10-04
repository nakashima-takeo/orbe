import AppKit

/// 行の列の行を描く色（どの列の行にも共通のもの）。動的な色を行ごと・字ごとに解かず、外観（ライト・ダーク）ごとに
/// 1 度だけ解いて使い回す。
struct RowColors {
  /// `text.primary`。
  let primary: CGColor
  /// `text.secondary`。
  let secondary: CGColor
  /// `text.muted`。
  let muted: CGColor
  /// `editor.text`。
  let text: CGColor
  /// `editor.tertiary`。
  let tertiary: CGColor
  /// 選択の地 `selectionFill`（焦点の有無で変えない）。
  let selection: CGColor
  private let chips: [ChipTint: (text: CGColor, ground: CGColor)]

  @MainActor private static let resolved = PerAppearance { RowColors() }

  @MainActor static func of(_ appearance: NSAppearance) -> RowColors { resolved(appearance) }

  private init() {
    primary = Theme.Color.textPrimary.cgColor
    secondary = Theme.Color.textSecondary.cgColor
    muted = Theme.Color.textMuted.cgColor
    text = Theme.Color.editorText.cgColor
    tertiary = Theme.Color.editorTertiary.cgColor
    selection = Theme.Color.selectionFill.cgColor
    var chips: [ChipTint: (text: CGColor, ground: CGColor)] = [
      .mono: (primary, EditorStyle.fill(FileChipView.groundAlpha).cgColor)
    ]
    for hue in FileChip.Hue.allCases {
      chips[.hue(hue)] = (
        hue.color.cgColor, hue.color.withAlphaComponent(FileChipView.groundAlpha).cgColor
      )
    }
    self.chips = chips
  }

  /// チップの字と地。
  func chip(_ tint: ChipTint) -> (text: CGColor, ground: CGColor) {
    chips[tint]!
  }
}

/// チップの色合い。
enum ChipTint: Hashable {
  /// 色相の無い種別（主文字と淡い塗り）。
  case mono
  case hue(FileChip.Hue)
}

extension FileChip {
  var tint: ChipTint { hue.map(ChipTint.hue) ?? .mono }
}

/// 外観（ライトかダークか）ごとに 1 度だけ作る値。作るときはその外観を今の描画の外観にして、動的な色を解く。
@MainActor
final class PerAppearance<Value> {
  private let make: () -> Value
  private var values: [Bool: Value] = [:]

  init(_ make: @escaping () -> Value) {
    self.make = make
  }

  func callAsFunction(_ appearance: NSAppearance) -> Value {
    let dark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    if let value = values[dark] { return value }
    var value: Value?
    appearance.performAsCurrentDrawingAppearance { value = make() }
    values[dark] = value
    return value!
  }
}
