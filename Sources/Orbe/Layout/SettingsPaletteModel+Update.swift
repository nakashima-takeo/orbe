import SwiftUI

/// 設定›アップデート サブパレット（見本 2c/2d）。行構成は固定 6 行（状態カード / バージョン情報 /
/// トグル3種 / 今すぐ確認）。状態カードと確認ボタンの中身は `UpdateState` を直接読むビューが
/// ライブに描き分けるため、非同期の状態遷移（進捗・完了）で行を組み直す必要はない——
/// 行の再構築はトグル切替（値スナップショットの反映）のときだけ行う。
extension SettingsPaletteModel {
  /// 固定行の index（rawValue = 行位置）。
  private enum UpdateRow: Int {
    case status = 0, version, autoCheck, autoDownload, autoInstall, checkNow
  }

  func rebuildUpdate() {
    guard let update else { return }
    render.fieldVisible = false
    render.fieldIsFilter = false
    render.breadcrumb = localization.string(.settingsUpdateBreadcrumb)
    render.placeholder = ""
    render.hint = localization.string(.settingsUpdateHint)
    render.rows = [
      PaletteModel.RowItem(
        label: "", customContent: AnyView(UpdateStatusCardRow(state: update))),
      PaletteModel.RowItem(
        label: "", enabled: false, customContent: AnyView(UpdateVersionRow(state: update))),
      toggleRow(.updateAutoCheckLabel, .updateAutoCheckSub, update.autoCheck),
      toggleRow(.updateAutoDownloadLabel, .updateAutoDownloadSub, update.autoDownload),
      toggleRow(.updateAutoInstallLabel, .updateAutoInstallSub, update.autoInstallOnQuit),
      PaletteModel.RowItem(
        label: "", customContent: AnyView(UpdateCheckNowRow(state: update))),
    ]
  }

  private func toggleRow(_ label: L10nKey, _ sub: L10nKey, _ isOn: Bool) -> PaletteModel.RowItem {
    PaletteModel.RowItem(
      label: "",
      customContent: AnyView(
        UpdateToggleRow(
          title: localization.string(label), subtitle: localization.string(sub), isOn: isOn)))
  }

  /// ↵。状態カードは第一アクション（適用待ち=再起動 / 失敗=再試行）、トグルは反転、確認は実行。
  func activateUpdateRow() {
    guard let update, let row = UpdateRow(rawValue: render.selected) else { return }
    switch row {
    case .status:
      switch update.phase {
      case .readyToRestart: update.onRestartNow()
      case .failed: update.onCheckNow()
      case .idle, .checking, .downloading, .upToDate: break
      }
    case .version:
      break  // 情報行（enabled=false のため通常は選択に来ない）
    case .autoCheck:
      update.autoCheck.toggle()
      setMode(.update, select: render.selected)  // トグル値のスナップショットを行へ反映
    case .autoDownload:
      update.autoDownload.toggle()
      setMode(.update, select: render.selected)
    case .autoInstall:
      update.autoInstallOnQuit.toggle()
      setMode(.update, select: render.selected)
    case .checkNow:
      update.onCheckNow()
    }
  }

  /// →。トグル行は反転（↵ と同義）、状態カードは適用待ちのとき変更内容へ、他は no-op。
  func rightArrowUpdateRow() {
    guard let update, let row = UpdateRow(rawValue: render.selected) else { return }
    switch row {
    case .autoCheck, .autoDownload, .autoInstall:
      activateUpdateRow()
    case .status:
      if case .readyToRestart = update.phase { update.onShowChanges() }
    case .version, .checkNow:
      break
    }
  }
}
