import Foundation

/// キー意図の分岐（↵ / ← / → / delete / esc / 入力欄の編集）。本体（状態・配線・モード遷移）から分離する。
///
/// `PaletteModel` の `on*` クロージャとテストの両方がここを駆動する。値を書く操作（スコープ反転・
/// stepper・toggle）は必ず `assign` の漏斗を通り、面ごとの確定は各サブパレットのファイルが持つ。
extension SettingsPaletteModel {
  func activate() {
    switch mode {
    case .root: activateRootRow()
    case .font:
      confirmFilter(rows: fontRows, defaultRowVisible: fontDefaultRowVisible) {
        SettingChange(SettingKeys.fontFamily, $0)
      }
    case .tabTitleFont:
      confirmFilter(rows: fontRows, defaultRowVisible: fontDefaultRowVisible) {
        SettingChange(SettingKeys.tabTitleFontFamily, $0)
      }
    case .emojiFont:
      guard Self.emojiFontModes.indices.contains(render.selected) else { return }
      assign(SettingChange(SettingKeys.emojiFont, Self.emojiFontModes[render.selected]))
      returnToRoot()
    case .theme:
      guard Self.themeModes.indices.contains(render.selected) else { return }
      assign(SettingChange(SettingKeys.theme, Self.themeModes[render.selected]))
      returnToRoot()
    case .agent:
      guard agents.indices.contains(render.selected) else { return }
      assign(SettingChange(SettingKeys.defaultAgent, agents[render.selected]))
      returnToRoot()
    case .agentStates:
      guard AgentStateIcon.Kind.allCases.indices.contains(render.selected) else { return }
      drillIntoState(AgentStateIcon.Kind.allCases[render.selected])
    case .agentIcon(let kind):
      let symbols = AgentStateIcon.curatedSymbols[kind] ?? []
      // 行 0＝Glass（既定・nil）、以降は curated symbol。範囲外は no-op。
      guard (0...symbols.count).contains(render.selected) else { return }
      let symbol = render.selected == 0 ? nil : symbols[render.selected - 1]
      assign(values.agentStateIconChange(kind: kind, symbol: symbol))
      returnToStates()
    case .worktreeDirPresets:
      activateWorktreeDirPresetRow()
    case .worktreeDirCustom:
      confirmWorktreeDir()
    case .language:
      guard Language.allCases.indices.contains(render.selected) else { return }
      onSelectLanguage(Language.allCases[render.selected])  // ストア更新はここで反映される
      returnToRoot()  // 新言語で root を組み直す
    case .update:
      activateUpdateRow()
    case .notificationSound:
      activateNotificationSoundRow()
    }
  }

  /// root 行の ↵。スコープ行は反転、toggle 行は反転、drillIn 行は潜る、stepper 行は no-op。
  private func activateRootRow() {
    guard visibleRootRows.indices.contains(render.selected) else { return }
    switch visibleRootRows[render.selected] {
    case .scope: toggleScope()
    case .setting(let d):
      switch d.activation {
      case .stepper: break  // stepper 行の Enter は no-op（現状維持）
      case .toggle: toggleValue(d)
      case .drillIn: drillIn(d.id)
      }
    case .language: drillIntoLanguage()
    case .update: drillIntoUpdate()
    case .cmdTapPermission: onOpenAccessibilitySettings()  // 権限あり時も System Settings を開くだけ
    }
  }

  /// filter モード（font）の ↵ 確定。先頭の既定行は nil 代入（＝既定チェーンへ戻す）、名前行はその値を
  /// 代入し root へ戻る。空状態の情報行では何もしない。`change` は選択値（or nil）を単一代入へ橋渡す。
  private func confirmFilter(
    rows: [String], defaultRowVisible: Bool, change: (String?) -> SettingChange
  ) {
    if defaultRowVisible && render.selected == 0 {  // 既定行 → 上書き/global を解除し既定チェーンへ
      assign(change(nil))
      returnToRoot()
      return
    }
    let i = render.selected - (defaultRowVisible ? 1 : 0)
    guard rows.indices.contains(i) else { return }  // 空状態の情報行では何もしない
    assign(change(rows[i]))
    returnToRoot()
  }

  /// ← ＝戻る/減算/反転。root のスコープ行/toggle 行は反転、stepper 行は減算、サブモードでは root へ戻る。
  func leftArrow() {
    switch mode {
    case .root:
      guard visibleRootRows.indices.contains(render.selected) else { return }
      switch visibleRootRows[render.selected] {
      case .scope: toggleScope()
      case .setting(let d):
        switch d.activation {
        case .stepper: adjustStepper(d, -1)
        case .toggle: toggleValue(d)
        case .drillIn: break
        }
      case .language, .update, .cmdTapPermission: break  // drillIn 行と同じく ← は無反応
      }
    case .font, .tabTitleFont, .emojiFont, .theme, .agent, .agentStates, .worktreeDirPresets,
      .language, .update, .notificationSound:
      returnToRoot()
    case .worktreeDirCustom: break  // editor 入力欄の ← はカーソル移動（ここへは届かない）。戻るは esc
    case .agentIcon: returnToStates()  // 1 段ずつ浅く（アイコン候補→状態一覧）
    }
  }

  /// → の意味。true を返すとキーを消費。root のスコープ行/toggle 行は反転、stepper 行は増算、drillIn 行は潜る。
  func rightArrow() -> Bool {
    if case .agentStates = mode {
      activate()  // → は状態一覧からアイコン候補へ潜る（↵ と同義）
      return true
    }
    if case .update = mode {
      rightArrowUpdateRow()  // トグル行は反転、他は no-op（↵ と同じ意味の部分集合）
      return true
    }
    if case .worktreeDirPresets = mode {
      // → は「潜る」意味だけを持つ。1 段深いのは chevron のある「カスタム…」行だけ。
      guard render.selected == worktreeDirCustomRow else { return false }
      drillIntoWorktreeDirCustom()
      return true
    }
    guard case .root = mode, visibleRootRows.indices.contains(render.selected) else { return false }
    switch visibleRootRows[render.selected] {
    case .scope: toggleScope()
    case .setting(let d):
      switch d.activation {
      case .stepper: adjustStepper(d, 1)
      case .toggle: toggleValue(d)
      case .drillIn: drillIn(d.id)
      }
    case .language: drillIntoLanguage()
    case .update: drillIntoUpdate()
    case .cmdTapPermission: onOpenAccessibilitySettings()
    }
    return true
  }

  /// delete＝workspace スコープの上書き行を解除して global 継承へ戻す（root のみ）。
  func deleteKey() {
    guard case .root = mode, values.scope == .workspace,
      visibleRootRows.indices.contains(render.selected),
      case .setting(let d) = visibleRootRows[render.selected],
      values.isOverriddenByWorkspace(d.id)
    else { return }
    assign(values.clearChange(for: d.id))
    rebuild()
  }

  /// スコープを反転して root を再構築する。
  private func toggleScope() {
    values.toggleScope()
    rebuild()
  }

  /// Esc。root では閉じ、サブモードでは 1 段ずつ浅くなる。worktreeDir のカスタム入力は保存せず一覧へ戻る。
  func escape() {
    switch mode {
    case .root: onDismiss()
    case .font, .tabTitleFont, .emojiFont, .theme, .agent, .agentStates, .worktreeDirPresets,
      .language, .update, .notificationSound:
      returnToRoot()
    case .agentIcon: returnToStates()  // 1 段ずつ浅く
    case .worktreeDirCustom: returnToWorktreeDirPresets()  // 同上（カスタム入力→プリセット一覧）
    }
  }

  func queryChanged() {
    switch mode {
    case .root, .font, .tabTitleFont: break  // フィルタ入力を持つモードのみ再構築
    case .worktreeDirCustom:
      // 編集は不正確定のエラー表示を下げ（エラーは確定時にだけ評価する）、repo を区別しない旨の警告を
      // 入力へ追従させる。行はすべて選択不可の情報行なので選択は動かさない。
      worktreeDirError = nil
      rebuild()
      return
    default: return
    }
    render.place(0)  // 行集合が入れ替わるため選択は先頭へ戻す
    rebuild()
  }

  /// direction は ±1。範囲・刻みは descriptor の domain から読む。現在値は実効値（スコープ依存）。
  private func adjustStepper(_ d: SettingDescriptor, _ direction: Int) {
    guard case .intRange(let range, let step, _) = d.domain,
      case .int(let current) = values.effectiveValue(d.id)
    else { return }
    let clamped = min(range.upperBound, max(range.lowerBound, current + direction * step))
    guard clamped != current else { return }  // 範囲端ではクランプして適用しない
    assign(SettingChange(id: d.id, value: .int(clamped)))
    rebuild()
  }

  /// toggle 行の値を反転して適用する。←/→/↵ すべてこれを呼び、毎回反転を適用する（端クランプは無い）。
  private func toggleValue(_ d: SettingDescriptor) {
    guard case .toggle = d.activation, case .bool(let current) = values.effectiveValue(d.id) else {
      return
    }
    assign(SettingChange(id: d.id, value: .bool(!current)))
    rebuild()
  }
}
