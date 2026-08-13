import SwiftUI

/// 通知音サブパレットの試聴と確定。本体（状態機械）から分離する。
///
/// この面の中核は**聴くことと決めることを分けてある**こと。↑↓・ホバー・⇥ はその場で鳴らすだけで
/// 設定を一切書かず（`assign` を通らず）、書くのは ↵ の確定だけ。だから 12 案を流し聴きしてから
/// ← / esc で戻れば、設定は開いたときのままになる。
extension SettingsPaletteModel {
  /// 試聴対象の切替（⇥ とセグメントのクリックが共有する）。反転した時点で今いる行を新しい対象で
  /// 鳴らし直す——切り替えた結果が耳で分かるため。
  private func applyPreviewEvent(_ event: AgentSoundEvent) {
    previewEvent = event
    rebuild()  // セグメントの選択表示を追従させる
    previewSelectedRow()
  }

  /// ⇥ で試聴対象（完了 ⇄ 入力待ち）を反転する。リスト直上のセグメントが今どちらを聴く面かを語る。
  func togglePreviewEvent() -> Bool {
    guard isNotificationSoundMode else { return false }
    applyPreviewEvent(previewEvent == .done ? .waiting : .done)
    return true
  }

  /// セグメントのクリック。同じセグメントを押しても鳴らし直す（クリックは「鳴らせ」という明示の操作）。
  func selectPreviewEvent(_ index: Int) {
    guard isNotificationSoundMode, AgentSoundEvent.allCases.indices.contains(index) else { return }
    applyPreviewEvent(AgentSoundEvent.allCases[index])
  }

  /// 現在行の試聴。通知音サブパレットにいるときだけ効き、行 0（なし）は鳴らさず止めるだけ。
  /// 選択が**ユーザ操作で**動いた通知（`onSelectionChanged`）と ⇥ の鳴らし直しがここへ来る
  /// ——面の組み立てによる配置（`PaletteModel.place`）は通知を出さないので、入場では鳴らない。
  func previewSelectedRow() {
    guard isNotificationSoundMode else { return }
    let sounds = NotificationSound.allCases
    let index = render.selected - 1  // 行 0 は「なし（オフ）」
    let sound = sounds.indices.contains(index) ? sounds[index] : nil
    onPreviewSound?(sound, previewEvent, values.effNotificationSoundVolume)
    lightPreviewIndicator(sound: sound, row: render.selected)
  }

  /// EQ を今鳴っている行へ立て、合成長ぶん経ったら畳む。再生層は完了を通知しないが、音はその場で
  /// 合成するので**長さは定義から確定している**（`SoundCatalog.duration`）。世代で先行の予約を無効化する。
  private func lightPreviewIndicator(sound: NotificationSound?, row: Int) {
    previewGeneration &+= 1
    let generation = previewGeneration
    guard let sound else {
      previewingRow = nil
      syncPreviewAccessory()
      return
    }
    previewingRow = row
    syncPreviewAccessory()
    schedulePreviewEnd(SoundCatalog.duration(sound, previewEvent)) { [weak self] in
      guard let self, self.previewGeneration == generation else { return }
      self.previewingRow = nil
      self.syncPreviewAccessory()
    }
  }

  /// 面を移るとき（`setMode`）に呼ぶ。EQ を畳み、予約中の消灯も無効化する
  /// ——モデル側に「鳴りっぱなし」の状態を残さないため。
  func cancelPreviewIndicator() {
    previewGeneration &+= 1
    previewingRow = nil
    syncPreviewAccessory()
  }

  /// 試聴中の行を `render.rowAccessory` へ写す。EQ の色は試聴対象の状態色（`glyphKind`）で解決する
  /// ——セグメントのグリフ色と 1 経路を共有し、状態色の二重定義を作らない。
  private func syncPreviewAccessory() {
    guard isNotificationSoundMode, let row = previewingRow else {
      render.rowAccessory = nil
      return
    }
    render.rowAccessory = PaletteModel.RowAccessory(
      row: row, view: AnyView(EqBarsView(color: previewEvent.glyphKind.stateColor)))
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
