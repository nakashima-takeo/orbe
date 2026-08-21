import OrbeSound
import SwiftUI

/// 通知音の試聴と確定。本体（状態機械）から分離する。
///
/// 通知音サブパレットの中核は**聴くことと決めることを分けてある**こと。↑↓・ホバー・⇥ はその場で
/// 鳴らすだけで設定を一切書かず（`assign` を通らず）、書くのは ↵ の確定だけ。だから 12 案を流し聴き
/// してから ← / esc で戻れば、設定は開いたときのままになる。
///
/// 鳴らす動作そのもの（`playPreview`）は面に依らない 1 経路で、「いつ・何を鳴らすか」は呼び出し側が
/// 持つ——サブパレットは「選択行の案を `previewEvent` で」、root の音量行は「実効案を `done` で」。
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
  ///
  /// カスタム行は**確定後と同じ解決**（フォールバック込み）で鳴らす。ただし音源が 1 つも
  /// 取り込まれていない完全未構成のときは解除行と同じく鳴らさない——選ぶ対象がまだ無い行で、
  /// 紋章の音だけが鳴っても何を確かめたことにもならない。
  func previewSelectedRow() {
    guard isNotificationSoundMode else { return }
    playPreview(previewSource(row: render.selected), event: previewEvent, row: render.selected)
  }

  /// 通知音サブの行 → 鳴らす音源（nil＝鳴らさず止めるだけ）。
  private func previewSource(row: Int) -> ResolvedSource? {
    if row == notificationSoundCustomRow {
      guard !values.hasNoCustomSound else { return nil }
      return values.effSoundSource(choice: .custom, event: previewEvent)
    }
    let sounds = NotificationSound.allCases
    let index = row - 1  // 行 0 は「なし（オフ）」
    return sounds.indices.contains(index) ? .synth(sounds[index]) : nil
  }

  /// 音量 stepper が値を実際に動かしたときの試聴。新しい実効音量で、現在の実効案の `done` を鳴らす
  /// ——音量は数字でなく耳で決めるものだから。オン/オフが off でも鳴る（サブパレットの試聴と同じ扱いで、
  /// 案の設定値は off のままでも保持されている）。音量以外の stepper は素通しする。
  func previewVolumeChange(_ d: SettingDescriptor) {
    guard d.id == .notificationSoundVolume else { return }
    playPreview(
      values.effSoundSource(choice: values.effNotificationSound, event: .done), event: .done,
      row: render.selected)
  }

  /// 試聴の 1 経路。音を 1 つ鳴らし、その行に EQ を立てて音の長さぶんで畳む。
  /// **どの面から呼ばれるかを問わない**——「いつ・何を鳴らすか」は呼び出し側が持ち、ここは
  /// 「鳴らす・光らせる」だけを持つ。前の音を止めて鳴らし直すのは再生層の責務（`SoundPlayer` が毎回
  /// stop してから鳴らす）なので、ここに時間の規則は無い。音量はこのパレットが見せているスコープの
  /// 実効値——耳と root 行の表示が食い違わないため。
  func playPreview(_ source: ResolvedSource?, event: AgentSoundEvent, row: Int) {
    onPreviewSound?(source, event, values.effNotificationSoundVolume)
    lightPreviewIndicator(source: source, event: event, row: row)
  }

  /// EQ を今鳴っている行へ立て、音の長さぶん経ったら畳む。再生層は完了を通知しないが、
  /// **長さはどちらの音源でも先に確定している**——世代で先行の予約を無効化する。
  private func lightPreviewIndicator(source: ResolvedSource?, event: AgentSoundEvent, row: Int) {
    previewGeneration &+= 1
    let generation = previewGeneration
    guard let source else {
      previewIndicator = nil
      syncPreviewAccessory()
      return
    }
    previewIndicator = PreviewIndicator(row: row, event: event)
    syncPreviewAccessory()
    schedulePreviewEnd(previewDuration(source, event: event)) { [weak self] in
      guard let self, self.previewGeneration == generation else { return }
      self.previewIndicator = nil
      self.syncPreviewAccessory()
    }
  }

  /// EQ の点灯時間。合成は定義から（`SoundCatalog.duration`）、取り込み済みは取り込み時に測って
  /// 設定値へ書いた長さから引く。引けないときは取り込みの長さ上限を使う——実体は必ずその上限以下
  /// なので、鳴り終わる前に EQ が消えることはない。
  private func previewDuration(_ source: ResolvedSource, event: AgentSoundEvent) -> Double {
    switch source {
    case .synth(let sound): return SoundCatalog.duration(sound, event)
    case .imported(let file):
      return values.customSound(file: file)?.duration ?? SoundImport.maxDuration
    }
  }

  /// 面を移るとき（`setMode`）と、絞り込みで行集合が入れ替わるときに呼ぶ。EQ を畳み、予約中の消灯も
  /// 無効化する——モデル側に「鳴りっぱなし」の状態を残さないため。
  func cancelPreviewIndicator() {
    previewGeneration &+= 1
    previewIndicator = nil
    syncPreviewAccessory()
  }

  /// 試聴中の行を `render.rowAccessory` へ写す。EQ の色は**鳴らした対象**の状態色（`glyphKind`）で
  /// 解決する——セグメントのグリフ色と 1 経路を共有し、状態色の二重定義を作らない。
  private func syncPreviewAccessory() {
    guard let indicator = previewIndicator else {
      render.rowAccessory = nil
      return
    }
    render.rowAccessory = PaletteModel.RowAccessory(
      row: indicator.row, view: AnyView(EqBarsView(color: indicator.event.glyphKind.stateColor)))
  }

  /// 通知音サブの ↵。行 0（なし）はオフにするだけで**選択の値は触らない**（再度オンにしたら戻る）。
  /// 案の行はその案を確定し、オフだったなら同時にオンへ戻す（選んだ音が鳴らないのは意図と食い違う）。
  ///
  /// カスタム行だけは、まだ何も取り込んでいなければ確定でなく `→` と同じ「潜る」になる
  /// ——確定しても鳴らせる音が無い状態を作らず、次にやることへそのまま連れていく。
  func activateNotificationSoundRow() {
    let sounds = NotificationSound.allCases
    if render.selected == 0 {
      assign(SettingChange(SettingKeys.notificationSoundEnabled, false))
    } else if render.selected == notificationSoundCustomRow {
      guard values.effCustomSoundDone != nil else {
        drillIntoNotificationSoundCustom()
        return
      }
      confirmNotificationSound(.custom)
    } else {
      let index = render.selected - 1
      guard sounds.indices.contains(index) else { return }
      confirmNotificationSound(.preset(sounds[index]))
    }
    returnToRoot()
  }

  /// 選択を確定し、オフだったなら同時にオンへ戻す。
  private func confirmNotificationSound(_ choice: AgentSoundChoice) {
    let wasEnabled = values.effNotificationSoundEnabled
    assign(SettingChange(SettingKeys.notificationSound, choice))
    if !wasEnabled { assign(SettingChange(SettingKeys.notificationSoundEnabled, true)) }
  }
}
