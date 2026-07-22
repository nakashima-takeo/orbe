import SwiftUI

/// root（絞り込み入力欄つき一覧）の行組み立て。本体（状態機械）から分離する。
/// 行の意味（`RootRow`）と表示中の部分集合（`visibleRootRows`）は本体が持ち、ここは描画行だけを作る。
extension SettingsPaletteModel {
  func rebuildRoot() {
    render.fieldVisible = true
    render.fieldIsFilter = true  // ← を onLeft に回す＝root の stepper/toggle/scope/戻る意味を維持
    render.breadcrumb = nil
    render.placeholder = localization.string(.settingsFilterPlaceholder)
    render.hint =
      values.scope == .workspace
      ? localization.string(.settingsRootHintWorkspace)
      : localization.string(.settingsRootHintGlobal)

    let query = render.query.trimmingCharacters(in: .whitespaces)
    visibleRootRows =
      query.isEmpty
      ? rootRows
      : rootRows.filter { rootSearchText($0).localizedCaseInsensitiveContains(query) }

    guard !visibleRootRows.isEmpty else {
      render.rows = [
        PaletteModel.RowItem(label: localization.string(.settingsNoMatch), enabled: false)
      ]
      return
    }
    render.rows = visibleRootRows.map { row in
      switch row {
      case .scope:
        return PaletteModel.RowItem(
          label: localization.string(.settingsScopeWord) + "  " + values.scopeLabel(localization),
          chevron: false)
      case .setting(let d):
        let inherited = values.scope == .workspace && !values.isOverriddenByWorkspace(d.id)
        // workspace スコープ: 未上書きは「（継承）」＋淡色。global スコープ: WS が上書き中の行は
        // 画面に効いている値を注記する（淡色にはしない——ここでの ↵ の着地点は global 値のまま）。
        let note =
          inherited
          ? localization.string(.settingsInheritedNote)
          : values.workspaceOverrideNote(d, localization)
        return PaletteModel.RowItem(
          label: localization.string(d.labelKey) + "  " + rootValueDisplay(d), chevron: d.isDrillIn,
          inherited: inherited, detail: note)
      case .language:
        return PaletteModel.RowItem(
          label: localization.string(.settingsLanguageLabel) + "  "
            + localization.language.displayName,
          chevron: true)
      case .update:
        return PaletteModel.RowItem(
          label: localization.string(.settingsUpdateLabel) + "  v"
            + (update?.currentVersion ?? ""),
          chevron: true)
      }
    }
  }

  /// root 行の絞り込み対象テキスト（ラベル本体のみ。現在値・（継承）は含めず値変動で一致が揺れない）。
  private func rootSearchText(_ row: RootRow) -> String {
    switch row {
    case .scope: return localization.string(.settingsScopeWord)
    case .setting(let d): return localization.string(d.labelKey)
    case .language: return localization.string(.settingsLanguageLabel)
    case .update: return localization.string(.settingsUpdateLabel)
    }
  }

  /// root 設定行の現在値表示（そのスコープの実効値）。defaultAgent は解決済みデフォルト、
  /// フォント未設定は既定の実フォント名。検出ゼロで解決不能のときだけ「（未設定）」へ縮退する。
  private func rootValueDisplay(_ d: SettingDescriptor) -> String {
    if case .defaultAgent = d.id { return resolvedAgent ?? unsetText(d) }
    return values.effectiveDisplay(d, localization) ?? unsetText(d)
  }

  /// drillIn 項目の未設定表示（現在言語）。placeholder キー未設定は空文字。
  private func unsetText(_ d: SettingDescriptor) -> String {
    d.unsetPlaceholderKey.map { localization.string($0) } ?? ""
  }
}
