import Foundation

/// 設定パレットが表示・編集する設定値の解決モデル（generic）。
/// global 層・アクティブ workspace の上書き層・現在スコープを束ね、実効値／継承・上書き判定／単一代入の適用を
/// 1 箇所に閉じる。値の語彙（単位・表示）は descriptor の `display` が持ち、ここは解決だけを担う。
struct ScopedSettingsValues {
  var scope: SettingsScope
  /// global 層（settings.json 由来）。global スコープの編集はここへ書く。
  var global: SettingsLayer
  /// アクティブ workspace の上書き層。workspace スコープの編集はここへ書く。
  var override: SettingsLayer

  init(
    scope: SettingsScope = .global, global: SettingsLayer = SettingsLayer(),
    override: SettingsLayer = SettingsLayer()
  ) {
    self.scope = scope
    self.global = global
    self.override = override
  }

  /// スコープ行の値表示（現在言語）。呼び出し側（SettingsPaletteModel）がストアを渡す。
  func scopeLabel(_ l10n: LocalizationStore) -> String {
    l10n.string(scope == .global ? .settingsScopeGlobal : .settingsScopeWorkspace)
  }

  mutating func toggleScope() { scope = (scope == .global) ? .workspace : .global }

  /// アクティブ workspace が当該項目を上書きしているか（スコープ非依存の事実）。
  func isOverriddenByWorkspace(_ id: SettingID) -> Bool { override.value(id) != nil }

  /// 現在スコープの実効層（workspace＝global に override を重ねる・global＝global そのまま）。
  /// これが「そのスコープでの ↵ の着地点」の SSOT。
  var effectiveLayer: SettingsLayer {
    scope == .workspace ? global.overlaid(with: override) : global
  }

  private var effective: EffectiveSettings { EffectiveSettings(effectiveLayer) }

  /// 型消去のまま現在スコープの実効値（明示 ?? 既定）を読む（stepper/toggle の generic 編集・表示が使う）。
  func effectiveValue(_ id: SettingID) -> SettingValue? {
    effectiveLayer.value(id) ?? SettingsRegistry.descriptor(id).defaultValue()
  }

  // 実効値の typed 読み（サブパレット・stepper/toggle が使う）。
  var effFontSize: Int { effective[SettingKeys.fontSize] }
  var effBackgroundOpacity: Int { effective[SettingKeys.backgroundOpacity] }
  var effBackgroundBlur: Bool { effective[SettingKeys.backgroundBlur] }
  var effCursorStyleBlink: Bool { effective[SettingKeys.cursorStyleBlink] }
  var effDevFeatures: Bool { effective[SettingKeys.devFeaturesEnabled] }
  var effFontFamily: String? { effective[SettingKeys.fontFamily] }
  var effTabTitleFontFamily: String? { effective[SettingKeys.tabTitleFontFamily] }
  var effEmojiFont: EmojiFontMode { effective[SettingKeys.emojiFont] }
  var effTheme: ThemeMode { effective[SettingKeys.theme] }
  var effDefaultAgent: String? { effective[SettingKeys.defaultAgent] }
  var effWorktreePath: String { effective[SettingKeys.worktreePath] }

  /// 実効の状態アイコンマップ（whole-map・A案）。
  var effAgentStateIcons: [AgentStateIcon.Kind: String] {
    AgentStateIcon.decode(effective[SettingKeys.agentStateIcons])
  }

  /// 状態の実効 symbol（マップに無ければ nil＝Glass）。
  func effSymbol(for kind: AgentStateIcon.Kind) -> String? { effAgentStateIcons[kind] }

  /// 状態を 1 つ差し替えた whole-map 単一代入を組む（snapshot-on-edit）。symbol==nil は Glass（マップから除く）。
  /// 起点は `effAgentStateIcons`——未上書き WS の初編集で global マップ全体をスナップショットしてその WS が所有する。
  func agentStateIconChange(kind: AgentStateIcon.Kind, symbol: String?) -> SettingChange {
    var map = effAgentStateIcons
    if let symbol { map[kind] = symbol } else { map.removeValue(forKey: kind) }
    return SettingChange(SettingKeys.agentStateIcons, AgentStateIcon.encode(map))
  }

  // MARK: - 値の表示

  /// root 行の現在値表示（そのスコープの実効値）。フォント未設定は既定の実フォント名へ解決する。
  /// defaultAgent は解決に検出結果が要るため nil を返す（呼び出し側が解決済みデフォルトを出す）。
  func effectiveDisplay(_ d: SettingDescriptor, _ l10n: LocalizationStore) -> String? {
    if d.id == .defaultAgent { return nil }
    if d.id == .fontFamily {
      return effFontFamily ?? l10n.format(.settingsDefaultFont, SettingsRegistry.defaultFontFamily)
    }
    if d.id == .tabTitleFontFamily {
      return effTabTitleFontFamily
        ?? l10n.format(.settingsDefaultFont, l10n.string(.settingsTabTitleFontSystemName))
    }
    guard let v = effectiveValue(d.id) else { return nil }
    return d.display(v, l10n)
  }

  /// font サブ先頭行（解除行）のラベル。**その行の ↵ がそのスコープで着地する値**を出す。
  /// - global: 既定チェーンの実フォントへ落ちる。
  /// - workspace: 上書きを解除して global 値を継承する（global も未設定なら既定チェーンの実フォント）。
  func fontResetRowLabel(_ l10n: LocalizationStore) -> String {
    scope == .global
      ? l10n.format(.settingsDefaultFont, SettingsRegistry.defaultFontFamily)
      : l10n.format(
        .settingsInheritGlobal, global[SettingKeys.fontFamily] ?? SettingsRegistry.defaultFontFamily
      )
  }

  /// タブタイトルフォントサブ先頭行（解除行）のラベル。font サブと同じ「↵ が着地する値を名乗る」規約:
  /// - global: 既定（システム等幅 11pt）へ落ちる。
  /// - workspace: 上書きを解除して global 値を継承する（global も未設定ならシステム等幅）。
  func tabTitleFontResetRowLabel(_ l10n: LocalizationStore) -> String {
    let systemName = l10n.string(.settingsTabTitleFontSystemName)
    return scope == .global
      ? l10n.format(.settingsDefaultFont, systemName)
      : l10n.format(.settingsInheritGlobal, global[SettingKeys.tabTitleFontFamily] ?? systemName)
  }

  /// global スコープでアクティブ WS がこの行を上書きしているときの注記（画面に効いている値との差）。
  /// 上書きしていない行と workspace スコープ（実効値そのものを出す）では nil。
  func workspaceOverrideNote(_ d: SettingDescriptor, _ l10n: LocalizationStore) -> String? {
    guard scope == .global, let v = override.value(d.id) else { return nil }
    return l10n.format(.settingsWorkspaceOverrideNote, d.display(v, l10n))
  }

  // MARK: - 適用

  /// 単一代入をスコープに応じ global／override へ反映する（提示元への通知は呼び出し側）。
  mutating func apply(_ change: SettingChange) {
    switch scope {
    case .global: global.apply(change)
    case .workspace: override.apply(change)
    }
  }

  /// 当該項目を解除する単一代入（value=nil）。
  func clearChange(for id: SettingID) -> SettingChange { SettingChange(id: id, value: nil) }
}
