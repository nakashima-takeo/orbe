import Foundation

/// 通知音サブパレットの試聴と確定。本体（状態機械）から分離する。
///
/// この面の中核は**聴くことと決めることを分けてある**こと。↑↓・ホバー・⇥ はその場で鳴らすだけで
/// 設定を一切書かず（`assign` を通らず）、書くのは ↵ の確定だけ。だから 12 案を流し聴きしてから
/// ← / esc で戻れば、設定は開いたときのままになる。
extension SettingsPaletteModel {
  /// ⇥ で試聴対象（完了 ⇄ 入力待ち）を反転し、今いる行を新しい対象で鳴らし直す
  /// ——切り替えた結果が耳で分かるため。ヘッダのセグメントが今どちらの面かを語る。
  func togglePreviewEvent() -> Bool {
    guard isNotificationSoundMode else { return false }
    previewEvent = previewEvent == .done ? .waiting : .done
    rebuild()  // ヘッダのセグメント表示を追従させる
    previewSelectedRow()
    return true
  }

  /// 現在行の試聴。通知音サブパレットにいるときだけ効き、行 0（なし）は鳴らさず止めるだけ。
  /// 選択が**ユーザ操作で**動いた通知（`onSelectionChanged`）と ⇥ の鳴らし直しがここへ来る
  /// ——面の組み立てによる配置（`PaletteModel.place`）は通知を出さないので、入場では鳴らない。
  func previewSelectedRow() {
    guard isNotificationSoundMode else { return }
    let sounds = NotificationSound.allCases
    let index = render.selected - 1  // 行 0 は「なし（オフ）」
    onPreviewSound?(
      sounds.indices.contains(index) ? sounds[index] : nil, previewEvent,
      values.effNotificationSoundVolume)
  }

  /// 通知音サブの ↵。行 0（なし）はオフにするだけで**音案の値は触らない**（再度オンにしたら戻る）。
  /// 案の行はその案を確定し、オフだったなら同時にオンへ戻す（選んだ音が鳴らないのは意図と食い違う）。
  func activateNotificationSoundRow() {
    let sounds = NotificationSound.allCases
    if render.selected == 0 {
      assign(SettingChange(SettingKeys.notificationSoundEnabled, false))
    } else {
      let index = render.selected - 1
      guard sounds.indices.contains(index) else { return }
      let wasEnabled = values.effNotificationSoundEnabled
      assign(SettingChange(SettingKeys.notificationSound, sounds[index]))
      if !wasEnabled { assign(SettingChange(SettingKeys.notificationSoundEnabled, true)) }
    }
    returnToRoot()
  }
}
