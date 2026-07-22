import Foundation

/// 設定パレットのドリル遷移（root ⇄ サブパレット、状態一覧 ⇄ アイコン候補）。本体（状態機械）から分離する。
/// mode の切替そのものは `setMode` が担い、ここは「どこへ潜り・どこへ戻るか」と選択復元 index の管理だけを持つ。
extension SettingsPaletteModel {
  /// SettingID（App 層）→ サブモード（Layout 内部）の semantic マップ。
  private func drillMode(for id: SettingID) -> Mode {
    switch id {
    case .fontFamily: return .font
    case .tabTitleFontFamily: return .tabTitleFont
    case .emojiFont: return .emojiFont
    case .theme: return .theme
    case .defaultAgent: return .agent
    case .agentStateIcons: return .agentStates
    case .fontSize, .backgroundOpacity, .backgroundBlur, .cursorStyleBlink, .devFeaturesEnabled:
      return .root  // toggle であって drillIn でない
    }
  }

  /// root 設定行から font/theme/agent/状態一覧サブパレットへ潜る。戻り時に選択を復元するため、潜った設定の
  /// 全行 rootRows 上の index（＝scope 行の分 +1）を覚える。絞り込み中の `render.selected` は
  /// visibleRootRows の部分集合を指すため、それでなく行の同一性（SettingID）から全行 index を引く。
  func drillIn(_ id: SettingID) {
    rootRowBeforeDrill = rootOrder.firstIndex { $0.id == id }.map { $0 + 1 } ?? rootRowBeforeDrill
    setMode(drillMode(for: id))
  }

  /// サブパレットから root へ戻る（`←`・`Esc`・確定のいずれでも）。潜った行へ選択を復元する。
  func returnToRoot() {
    setMode(.root, select: rootRowBeforeDrill)
  }

  /// 状態一覧からその状態のアイコン候補へ潜る。戻り時に状態行の選択を復元するため index を覚える。
  func drillIntoState(_ kind: AgentStateIcon.Kind) {
    stateRowBeforeDrill = render.selected
    setMode(.agentIcon(kind))
  }

  /// アイコン候補から状態一覧へ戻る（`←`・`Esc`・確定のいずれでも）。潜った状態行へ選択を復元する。
  func returnToStates() {
    setMode(.agentStates, select: stateRowBeforeDrill)
  }

  /// root の言語行（末尾固定）から言語サブパレットへ潜る。戻り時の選択復元用に末尾 index を覚える。
  func drillIntoLanguage() {
    rootRowBeforeDrill = 1 + rootOrder.count  // scope(0) ＋ 設定行 ＋ 末尾の言語行
    setMode(.language)
  }
}
