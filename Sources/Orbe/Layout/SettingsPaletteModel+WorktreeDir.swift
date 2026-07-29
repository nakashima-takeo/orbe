import Foundation

/// worktree-dir 面（プリセット一覧 → カスタム入力）の確定処理。本体（状態機械）から分離する。
/// 行の組み立ては `+Subpalette`、ドリル遷移は `+Navigation` が持つ。
extension SettingsPaletteModel {
  /// プリセット一覧の ↵。プリセット行はそのテンプレートを確定して root へ戻り、最終行「カスタム…」だけが
  /// テキスト入力へ 1 段深く潜る（値が決まったら root へ戻る、が一覧・入力に共通の着地規則）。
  func activateWorktreeDirPresetRow() {
    let presets = WorktreePathTemplate.presets
    if render.selected == worktreeDirCustomRow {
      drillIntoWorktreeDirCustom()
      return
    }
    guard presets.indices.contains(render.selected) else { return }
    assign(SettingChange(SettingKeys.worktreeDir, presets[render.selected].template))
    returnToRoot()
  }

  /// worktreeDir 入力（editor）の ↵ 確定。trim → 空なら解除（global は既定へ・workspace は継承へ。
  /// プリフィルで常に現在値から始まるため、全消し＋↵ は意図的な解除操作として成立する）→
  /// 不正なら情報行へ理由を出して入力モードに留まる → 妥当なら保存して root へ戻る。
  func confirmWorktreeDir() {
    let text = render.query.trimmingCharacters(in: .whitespaces)
    if text.isEmpty {
      assign(SettingChange(SettingKeys.worktreeDir, nil))
      returnToRoot()
      return
    }
    if let error = WorktreePathTemplate.validate(text) {
      worktreeDirError = worktreeDirErrorText(error)
      rebuild()
      return
    }
    assign(SettingChange(SettingKeys.worktreeDir, text))
    returnToRoot()
  }

  /// 検証エラーを現在言語の表示文言へ写す（純関数の理由 → UI 語彙はここだけが持つ）。
  private func worktreeDirErrorText(_ error: WorktreePathTemplate.ValidationError) -> String {
    switch error {
    case .unknownToken(let token):
      return localization.format(.settingsWorktreeDirErrUnknownToken, token)
    case .missingSlug: return localization.string(.settingsWorktreeDirErrMissingSlug)
    case .notAbsolute: return localization.string(.settingsWorktreeDirErrNotAbsolute)
    }
  }
}
