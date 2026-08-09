import Foundation

/// 通知音サブパレットの試聴と確定。本体（状態機械）から分離する。
///
/// この面の中核は**聴くことと決めることを分けてある**こと。↑↓・ホバー・⇥ はその場で鳴らすだけで
/// 設定を一切書かず（`assign` を通らず）、書くのは ↵ の確定だけ。だから 12 案を流し聴きしてから
/// ← / esc で戻れば、設定は開いたときのままになる。
extension SettingsPaletteModel {
  /// 面の組み立て中（`setMode` / `rebuild`）は試聴を止める。行が入れ替わって選択が動くのは
  /// ユーザの意図ではない——素朴に選択の setter へ繋ぐと、サブパレットに入った瞬間に鳴ってしまう。
  func withoutPreview(_ body: () -> Void) {
    let previous = suppressPreview
    suppressPreview = true
    body()
    suppressPreview = previous
  }

  /// 選択行が動いた。通知音サブパレットにいるときだけ、その行の音を現在の試聴対象で鳴らす。
  func selectionChanged() {
    guard !suppressPreview, isNotificationSoundMode else { return }
    previewSelectedRow()
  }

  /// ⇥ で試聴対象（完了 ⇄ 入力待ち）を反転し、今いる行を新しい対象で鳴らし直す
  /// ——切り替えた結果が耳で分かるため。ヘッダのセグメントが今どちらの面かを語る。
  func togglePreviewEvent() -> Bool {
    guard isNotificationSoundMode else { return false }
    previewEvent = previewEvent == .done ? .waiting : .done
    rebuild()  // ヘッダのセグメント表示を追従させる
    previewSelectedRow()
    return true
  }

  /// 現在行の試聴。行 0（なし）は鳴らさず、鳴っている音を止めるだけ。
  private func previewSelectedRow() {
    let sounds = NotificationSound.allCases
    let index = render.selected - 1  // 行 0 は「なし（オフ）」
    onPreviewSound?(sounds.indices.contains(index) ? sounds[index] : nil, previewEvent)
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
