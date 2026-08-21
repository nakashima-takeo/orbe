import Foundation
import OrbeSound

/// カスタム音源の設定サブ（通知音サブの 1 段奥）。行の組み立てと、その面での確定処理を持つ。
///
/// この面は**値を選ぶ面ではなくフォーム面**なので `●` を置かない（エージェントアイコンの状態一覧と
/// 同じ作法）。音源行の `↵`/`→` はファイル選択を開き、選んだその場で取り込んで値を書く
/// ——「決める」と「取り込む」を分けると、鳴らす瞬間まで失敗が分からない状態が生まれる。
extension SettingsPaletteModel {
  /// この面の行（notice を差し込んでも意味がズレないよう、index でなくこの kind で扱う）。
  enum SoundCustomRow: Int {
    case doneSource, waitingSource, sameAsDoneToggle
  }

  /// 取り込み失敗の理由行を先頭に出しているぶんの ずれ。
  var soundCustomRowOffset: Int { customSoundError == nil ? 0 : 1 }

  func soundCustomRowIndex(_ row: SoundCustomRow) -> Int { row.rawValue + soundCustomRowOffset }

  func soundCustomRow(at index: Int) -> SoundCustomRow? {
    SoundCustomRow(rawValue: index - soundCustomRowOffset)
  }

  /// 3 行（完了の音源 / 入力待ちの音源 / 同一化トグル）。同一化トグルが on の間、入力待ちの行は
  /// 無効行にして「（完了と同じ）」を出す——押せてしまうと、押した結果が効かない行になる。
  func rebuildNotificationSoundCustom() {
    render.fieldVisible = false
    render.fieldIsFilter = false
    // breadcrumb は行ラベルから組む（worktree のカスタム入力と同じ作法。文言を 2 箇所に持たない）。
    render.breadcrumb = "‹ " + localization.string(.settingsNotificationSoundCustom)
    render.placeholder = ""
    render.hint = localization.string(.settingsSoundCustomHint)
    currentRowIndex = nil  // 値を選ぶ面ではないので ● は持たない

    let sameAsDone = values.effCustomSoundWaitingSameAsDone
    let waitingValue =
      sameAsDone
      ? localization.string(.settingsSoundCustomSameAsDoneValue)
      : (values.effCustomSoundWaiting?.name ?? localization.string(.settingsSoundCustomUnset))

    var rows: [PaletteModel.RowItem] = []
    if let customSoundError {
      rows.append(PaletteModel.RowItem(label: customSoundError, enabled: false))
    }
    rows += [
      PaletteModel.RowItem(
        label: localization.string(.settingsSoundCustomDoneRow) + "  "
          + (values.effCustomSoundDone?.name ?? localization.string(.settingsSoundCustomUnset)),
        chevron: true),
      PaletteModel.RowItem(
        label: localization.string(.settingsSoundCustomWaitingRow) + "  " + waitingValue,
        chevron: !sameAsDone, enabled: !sameAsDone),
      PaletteModel.RowItem(
        label: localization.string(.settingsSoundCustomSameAsDone) + "  "
          + localization.string(sameAsDone ? .settingsToggleOn : .settingsToggleOff)),
    ]
    render.rows = rows
  }

  /// この面の `↵`（`→` も同義）。音源行はファイル選択→取り込み、トグル行は反転。
  func activateNotificationSoundCustomRow() {
    guard let row = soundCustomRow(at: render.selected) else { return }
    switch row {
    case .doneSource: importCustomSound(for: .done, into: row)
    case .waitingSource: importCustomSound(for: .waiting, into: row)
    case .sameAsDoneToggle:
      customSoundError = nil
      assign(
        SettingChange(
          SettingKeys.notificationSoundCustomWaitingSameAsDone,
          !values.effCustomSoundWaitingSameAsDone))
      rebuild()
      render.place(soundCustomRowIndex(row))
    }
  }

  /// ファイルを選ばせ、選んだその場で取り込んで現在のスコープへ書く。
  ///
  /// 成功したらその音を実効音量で 1 回鳴らし、その行に EQ を出す——取り込んだ結果が耳で分かる
  /// （音量行の試聴と同じ 1 経路）。失敗は面の先頭に理由 1 行で出し、鳴らす瞬間まで持ち越さない。
  /// キャンセルは no-op。
  ///
  /// 出口は 1 つに閉じる。理由行の有無で行 index の意味が変わる面なので、**行を組み直したら必ず
  /// 種別から選択を置き直す**——どこか 1 経路でも落とすと、選択が別の行（同一化トグル on のときは
  /// 押せないはずの行）へ黙って移り、次の ↵ が狙っていない設定キーを書き換える。
  private func importCustomSound(for event: AgentSoundEvent, into row: SoundCustomRow) {
    customSoundError = nil
    var imported: CustomSoundSource?
    if let url = pickSoundFile?(), let result = importSoundFile?(url) {
      switch result {
      case .success(let source):
        // 提示元がここで保存し、参照されなくなった旧ファイルを回収する
        assign(
          event == .done
            ? SettingChange(SettingKeys.notificationSoundCustomDone, source)
            : SettingChange(SettingKeys.notificationSoundCustomWaiting, source))
        imported = source
      case .failure(let error):
        customSoundError = customSoundErrorText(error, name: url.lastPathComponent)
      }
    }
    rebuild()
    let index = soundCustomRowIndex(row)  // 理由行の増減が確定した後に引き直す
    render.place(index)
    if let imported {
      playPreview(.imported(file: imported.file), event: event, row: index)
    }
  }

  /// 取り込み失敗の理由 → 現在言語の表示文言（純関数の理由 → UI 語彙はここだけが持つ）。
  private func customSoundErrorText(_ error: SoundFileImporter.ImportError, name: String) -> String
  {
    switch error {
    case .unreadable: return localization.format(.settingsSoundCustomErrUnreadable, name)
    case .silent: return localization.format(.settingsSoundCustomErrSilent, name)
    // 壊れているのは選んだファイルでなくアプリの保存先なので、名前は出さない。
    case .storageFailed: return localization.string(.settingsSoundCustomErrStorage)
    }
  }
}
