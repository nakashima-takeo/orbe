import AppKit

/// 検索結果の行だけが使う色（行に共通の色は `RowColors`）。外観（ライト・ダーク）ごとに 1 度だけ解いて使い回す。
struct SearchRowColors {
  /// 一致の地。
  let hit: CGColor
  /// 件数バッジの地。
  let countFill: CGColor

  @MainActor private static let resolved = PerAppearance { SearchRowColors() }

  @MainActor static func of(_ appearance: NSAppearance) -> SearchRowColors { resolved(appearance) }

  private init() {
    hit = Theme.Color.editorModified.withAlphaComponent(0.30).cgColor
    countFill = EditorStyle.fill(0.10).cgColor
  }
}
