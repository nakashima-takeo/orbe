import OrbeEditorCore

/// シンボルの種類 → チップ（グリフ・色）の唯一の決定点。見本（editor/parts.tsx の SymbolChip）の 3 つ（class 黄 C /
/// property sky P / method accent M）を種類の群へ広げ、文書の構造を持つ言語の種類は同じ言語のファイルの種別チップの色に
/// 合わせる。将来のアイコンテーマはこの表の差し替えで受ける（`FileChip` と同じ）。
struct SymbolChip: Equatable {
  let glyph: String
  let tint: ChipTint

  static func of(_ kind: OutlineKind) -> SymbolChip {
    switch kind {
    case .class, .struct, .enum, .interface, .type: SymbolChip(glyph: "C", tint: .hue(.yellow))
    case .function, .method, .constructor: SymbolChip(glyph: "M", tint: .accent)
    case .property, .variable, .constant, .enumMember, .key:
      SymbolChip(glyph: "P", tint: .hue(.sky))
    case .module: SymbolChip(glyph: "N", tint: .hue(.blue))
    case .heading: SymbolChip(glyph: "#", tint: .hue(.blue))
    case .element: SymbolChip(glyph: "<>", tint: .hue(.orange))
    case .selector: SymbolChip(glyph: "{}", tint: .hue(.violet))
    case .instruction: SymbolChip(glyph: "D", tint: .hue(.teal))
    }
  }
}
