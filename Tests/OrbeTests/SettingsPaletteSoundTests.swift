import OrbeSound
import XCTest

@testable import Orbe

/// 設定パレットの通知音まわり（root の 3 行・サブパレットの試聴と確定）。
/// 中核は「**聴くことと決めることを分けてある**」——行の移動と ⇥ は鳴らすだけで設定を書かず、
/// 書くのは ↵ の確定だけ。通知音行は root index 13（worktree の作成場所の次）。
@MainActor
final class SettingsPaletteSoundTests: OrbeTestCase {
  private let soundRow = 13

  private func model(sound: NotificationSound? = nil, volume: Int? = nil, enabled: Bool? = nil)
    -> SettingsPaletteModel
  {
    var global = SettingsLayer()
    global[SettingKeys.notificationSound] = sound
    global[SettingKeys.notificationSoundVolume] = volume
    global[SettingKeys.notificationSoundEnabled] = enabled
    return SettingsPaletteModel(
      values: ScopedSettingsValues(global: global), fontNames: [], agents: ["claude"],
      localization: LocalizationStore(language: .ja))
  }

  /// 適用された単一代入を順に記録する（1 操作で 2 件届く経路があるため最後の 1 件では足りない）。
  private func captureChanges(_ p: SettingsPaletteModel) -> () -> [SettingChange] {
    var changes: [SettingChange] = []
    p.onApply = { change, _ in changes.append(change) }
    return { changes }
  }

  /// 試聴の呼び出し 1 件。
  private struct Preview: Equatable {
    let sound: NotificationSound?
    let event: AgentSoundEvent
    let volume: Int
  }

  private func capturePreviews(_ p: SettingsPaletteModel) -> () -> [Preview] {
    var previews: [Preview] = []
    p.onPreviewSound = { sound, event, volume in
      previews.append(Preview(sound: sound, event: event, volume: volume))
    }
    return { previews }
  }

  private func drillIn(_ p: SettingsPaletteModel) {
    p.render.selected = soundRow
    p.render.onActivate()
  }

  // MARK: - root の 3 行

  /// 未設定は既定（案＝`NotificationSound.default`・音量 70%・オン）を出し、通知音行だけが潜れる。
  func testRootShowsThreeRowsWithDefaults() {
    let p = model()
    XCTAssertTrue(p.render.rows[soundRow].label.contains("通知音"))
    XCTAssertTrue(
      p.render.rows[soundRow].label.contains(
        LocalizationStore(language: .ja).string(NotificationSound.default.labelKey)))
    XCTAssertTrue(p.render.rows[soundRow].chevron, "drillIn 行")
    XCTAssertTrue(p.render.rows[soundRow + 1].label.contains("音量"))
    XCTAssertTrue(p.render.rows[soundRow + 1].label.contains("70%"))
    XCTAssertFalse(p.render.rows[soundRow + 1].chevron, "stepper 行")
    XCTAssertTrue(p.render.rows[soundRow + 2].label.contains("通知音のオン/オフ"))
    XCTAssertTrue(p.render.rows[soundRow + 2].label.contains("オン"))
    XCTAssertFalse(p.render.rows[soundRow + 2].chevron, "toggle 行")
  }

  /// オフのときの通知音行は保持している案名でなく「なし」を出す（鳴らない設定が鳴りそうに読めない）。
  func testRootShowsNoneWhenDisabled() {
    let p = model(sound: .steel, enabled: false)
    XCTAssertTrue(p.render.rows[soundRow].label.contains("なし"))
    XCTAssertFalse(p.render.rows[soundRow].label.contains("鋼"), "保持している案名は出さない")
  }

  /// 音量は 5 刻みの stepper（←→ でライブに動く）。
  func testVolumeStepsByFive() {
    let p = model(volume: 70)
    let changes = captureChanges(p)
    p.render.selected = soundRow + 1
    _ = p.render.onRight()
    XCTAssertEqual(changes().last?.value, .int(75))
    p.render.onLeft()
    p.render.onLeft()
    XCTAssertEqual(changes().last?.value, .int(65))
  }

  /// ← は 5% で止まる。0% まで下げられると試聴まで無音になり、聴きながら選べなくなる
  /// ——黙らせたい人にはオン/オフ行があり、音量が「鳴らない」をもう 1 つ持つ必要は無い。
  func testVolumeClampsAtFivePercent() {
    let p = model(volume: 10)
    let changes = captureChanges(p)
    p.render.selected = soundRow + 1
    p.render.onLeft()
    XCTAssertEqual(changes().last?.value, .int(5))
    p.render.onLeft()
    XCTAssertEqual(changes().last?.value, .int(5), "下限では値が動かない")
  }

  // MARK: - サブパレットの構成

  /// 行 0 が「なし（オフ）」、続いて 12 案。現在値（●・初期ハイライト）はオンなら案の行。
  func testSubpaletteRowsAndCurrentValue() {
    let p = model(sound: .wood)
    drillIn(p)
    XCTAssertEqual(p.render.breadcrumb, "‹ 通知音")
    XCTAssertFalse(p.render.fieldVisible, "絞り込み欄は持たない（⇥ が打鍵と衝突しない）")
    XCTAssertEqual(p.render.rows.count, 13)
    XCTAssertEqual(p.render.rows[0].label, "  なし（オフ）")
    XCTAssertEqual(p.render.rows[1].label, "  硝子")
    XCTAssertEqual(p.render.rows[3].label, "● 木肌", "現在値に ●")
    XCTAssertEqual(p.render.rows[12].label, "  深層")
    XCTAssertEqual(p.render.selected, 3, "現在値の行が初期ハイライト")
  }

  /// オフのときは行 0 に ● と初期ハイライトが乗る。
  func testSubpaletteMarksOffRowWhenDisabled() {
    let p = model(sound: .wood, enabled: false)
    drillIn(p)
    XCTAssertEqual(p.render.rows[0].label, "● なし（オフ）")
    XCTAssertEqual(p.render.selected, 0)
  }

  /// リスト直上のセグメントが試聴対象を、その下の一文が鳴る条件を、フッターが操作を語る。
  func testSegmentsShowPreviewTargetAndCaptionExplainsPreview() {
    let p = model()
    drillIn(p)
    XCTAssertEqual(p.render.segments.map(\.label), ["完了", "入力待ち"])
    XCTAssertEqual(p.render.segments.map(\.active), [true, false])
    XCTAssertEqual(p.render.segments.map(\.glyph), [.done, .waiting], "状態の語彙をグリフでも出す")
    XCTAssertFalse(p.render.caption.isEmpty, "鳴る条件はリスト直上の一文で言い切る")
    XCTAssertTrue(p.render.hint.contains("↑↓"))
    XCTAssertTrue(p.render.hint.contains("⇥"))
  }

  /// root へ戻るとセグメントと一文は消える（他の面へ持ち越さない）。
  func testSegmentsClearedOnReturn() {
    let p = model()
    drillIn(p)
    p.render.onLeft()
    XCTAssertTrue(p.render.segments.isEmpty)
    XCTAssertTrue(p.render.caption.isEmpty)
  }

  // MARK: - 試聴（聴くだけ。設定は書かない）

  /// 入場では鳴らない（現在値の行にハイライトが乗るだけ）。移動すればその案が鳴る。
  func testEntryIsSilentAndMovementPreviews() {
    let p = model(sound: .glass)
    let previews = capturePreviews(p)
    drillIn(p)
    XCTAssertTrue(previews().isEmpty, "入場では鳴らさない")
    p.render.onDown()  // 電紫
    XCTAssertEqual(previews().count, 1)
    XCTAssertEqual(previews().last?.sound, .pulse)
    XCTAssertEqual(previews().last?.event, .done, "入場時の試聴対象は完了")
  }

  /// 行 0（なし）では鳴らさない——止めるだけ（nil）。
  func testOffRowStopsInsteadOfPlaying() {
    let p = model(sound: .glass)
    let previews = capturePreviews(p)
    drillIn(p)
    p.render.onUp()  // 行 0（なし）
    XCTAssertEqual(p.render.selected, 0)
    XCTAssertEqual(previews().count, 1)
    XCTAssertNil(previews().last?.sound ?? nil, "鳴らさず止めるだけ")
  }

  /// 試聴の音量は**このパレットが見せているスコープの実効値**（root の音量行が出している値と同じ）。
  /// 提示元が別の解決（アクティブ workspace の実効値）を持ち込むと、表示と耳が食い違う。
  func testPreviewCarriesTheScopedVolume() {
    let p = model(volume: 40)
    let previews = capturePreviews(p)
    drillIn(p)
    p.render.onDown()
    XCTAssertEqual(previews().last?.volume, 40)
  }

  /// ホバーでも鳴る（ポインタ操作でも聴き比べられる）。
  /// 現在値を明示して入場行を固定する——既定を差し替えたときに入場行とホバー先が重なると、
  /// 「選択が動いていないので鳴らない」が正しい挙動のまま落ちる。
  func testHoverPreviews() {
    let p = model(sound: .glass)
    let previews = capturePreviews(p)
    drillIn(p)
    p.render.inputModality = .pointer
    p.render.hoverSelect(5)
    XCTAssertEqual(previews().last?.sound, NotificationSound.allCases[4])
  }

  /// 流し聴きは設定を一切書かない（↑↓ で全案を聴いても、← で戻れば元のまま）。
  func testMovementDoesNotAssign() {
    let p = model(sound: .glass)
    let changes = captureChanges(p)
    drillIn(p)
    for _ in 0..<12 { p.render.onDown() }
    p.render.onLeft()
    XCTAssertTrue(changes().isEmpty, "移動と戻りは値を書かない")
    XCTAssertTrue(p.render.rows[soundRow].label.contains("硝子"), "root の表示も元のまま")
    XCTAssertEqual(p.render.selected, soundRow, "潜った行へ選択を復元")
  }

  // MARK: - ⇥ とセグメントのクリックによる試聴対象の反転

  /// ⇥ でセグメントが反転し、今いる行を新しい対象で鳴らし直す。設定は書かない。
  func testTabFlipsPreviewTargetAndReplaysCurrentRow() {
    let p = model(sound: .wood)
    let previews = capturePreviews(p)
    let changes = captureChanges(p)
    drillIn(p)
    XCTAssertTrue(p.render.onTab())
    XCTAssertEqual(p.render.segments.map(\.active), [false, true])
    XCTAssertEqual(previews().count, 1)
    XCTAssertEqual(previews().last?.sound, .wood, "今いる行を鳴らし直す")
    XCTAssertEqual(previews().last?.event, .waiting)
    // 以降の移動も入力待ちで鳴る。
    p.render.onDown()
    XCTAssertEqual(previews().last?.event, .waiting)
    XCTAssertTrue(p.render.onTab())
    XCTAssertEqual(previews().last?.event, .done, "もう一度 ⇥ で完了へ戻る")
    XCTAssertTrue(changes().isEmpty, "⇥ は設定を書かない")
  }

  /// 潜り直すと試聴対象は必ず「完了」へ戻る（前回を持ち越さない）。
  func testPreviewTargetResetsOnReentry() {
    let p = model()
    drillIn(p)
    _ = p.render.onTab()
    XCTAssertEqual(p.previewEvent, .waiting)
    p.render.onEscape()  // root へ
    drillIn(p)
    XCTAssertEqual(p.previewEvent, .done)
    XCTAssertEqual(p.render.segments.map(\.active), [true, false])
  }

  /// root や他の面では ⇥ は消費しない（AppKit の focus 移動へ返す）。
  func testTabIsNotConsumedOutsideNotificationSound() {
    let p = model()
    XCTAssertFalse(p.render.onTab())
  }

  /// セグメントのクリックは ⇥ と同じ帰結（対象が変わり、今いる行が新しい対象で鳴る）。
  func testSegmentTapFlipsPreviewTargetLikeTab() {
    let p = model(sound: .wood)
    let previews = capturePreviews(p)
    let changes = captureChanges(p)
    drillIn(p)
    p.render.onTapSegment(1)  // 入力待ち
    XCTAssertEqual(p.previewEvent, .waiting)
    XCTAssertEqual(p.render.segments.map(\.active), [false, true])
    XCTAssertEqual(previews().last?.sound, .wood, "今いる行を鳴らし直す")
    XCTAssertEqual(previews().last?.event, .waiting)
    XCTAssertTrue(changes().isEmpty, "クリックは設定を書かない")
  }

  /// 同じセグメントのクリックでも鳴らし直す（クリックは「鳴らせ」という明示の操作）。
  func testSegmentTapOnActiveTargetReplays() {
    let p = model(sound: .wood)
    let previews = capturePreviews(p)
    drillIn(p)
    p.render.onTapSegment(0)  // 完了（すでに選択中）
    p.render.onTapSegment(0)
    XCTAssertEqual(previews().count, 2)
    XCTAssertEqual(previews().last?.event, .done)
  }

  /// 範囲外の index は何もしない（セグメントが空へ縮む更新パスでも壊れない）。
  func testSegmentTapOutOfRangeIsIgnored() {
    let p = model()
    let previews = capturePreviews(p)
    drillIn(p)
    p.render.onTapSegment(2)
    XCTAssertTrue(previews().isEmpty)
  }

  // MARK: - 試聴中の EQ（鳴っている行だけに出る）

  /// 鳴り終わりの予約を溜め、手で発火させる（合成長ぶん実時間を待たずに消灯を見る）。
  private func captureScheduledEnds(_ p: SettingsPaletteModel) -> () -> [() -> Void] {
    var ends: [() -> Void] = []
    p.schedulePreviewEnd = { _, fire in ends.append(fire) }
    return { ends }
  }

  /// 入場では EQ が出ず、試聴すると今いる行に出る。
  func testPreviewLightsIndicatorOnCurrentRow() {
    let p = model(sound: .glass)
    _ = captureScheduledEnds(p)
    drillIn(p)
    XCTAssertNil(p.render.rowAccessory, "入場では鳴らないので EQ も出ない")
    p.render.onDown()
    XCTAssertEqual(p.render.rowAccessory?.row, p.render.selected)
  }

  /// 解除行では鳴らないので EQ も出ない（鳴っていた EQ も畳む）。
  func testOffRowShowsNoIndicator() {
    let p = model(sound: .glass)
    _ = captureScheduledEnds(p)
    drillIn(p)
    p.render.onDown()
    XCTAssertNotNil(p.render.rowAccessory)
    p.render.selected = 0  // なし（オフ）
    XCTAssertNil(p.render.rowAccessory, "解除行では EQ を出さない")
  }

  /// 鳴り終わると EQ が消える。
  func testIndicatorClearsWhenSoundEnds() {
    let p = model(sound: .glass)
    let ends = captureScheduledEnds(p)
    drillIn(p)
    p.render.onDown()
    XCTAssertEqual(ends().count, 1)
    ends()[0]()
    XCTAssertNil(p.render.rowAccessory, "鳴り終わりで畳む")
  }

  /// 先行する消灯予約は後の試聴を消さない（↑↓ 連打で EQ が食い違わない）。
  func testStaleEndDoesNotClearLaterPreview() {
    let p = model(sound: .glass)
    let ends = captureScheduledEnds(p)
    drillIn(p)
    p.render.onDown()
    p.render.onDown()
    XCTAssertEqual(ends().count, 2)
    ends()[0]()  // 1 回目の予約が後から届く
    XCTAssertEqual(p.render.rowAccessory?.row, p.render.selected, "最後の試聴の EQ は残る")
  }

  /// 面を離れると EQ は畳まれ、予約中の消灯も無効化される。
  func testIndicatorClearsOnLeavingTheMode() {
    let p = model(sound: .glass)
    let ends = captureScheduledEnds(p)
    drillIn(p)
    p.render.onDown()
    p.render.onEscape()  // root へ
    XCTAssertNil(p.render.rowAccessory)
    ends()[0]()  // 予約が後から届いても何も起きない
    XCTAssertNil(p.render.rowAccessory)
  }

  // MARK: - 確定（↵ だけが値を書く）

  /// 案の行の ↵ でその案が確定し、root へ戻って表示が追従する。
  func testApplyFamily() {
    let p = model(sound: .glass)
    drillIn(p)
    let changes = captureChanges(p)
    p.render.onDown()  // 電紫
    p.render.onActivate()
    XCTAssertEqual(changes().count, 1, "オンのままなら書くのは案 1 件だけ")
    XCTAssertEqual(changes().first?.id, .notificationSound)
    XCTAssertEqual(changes().first?.value, .string("pulse"))
    XCTAssertNil(p.render.breadcrumb, "root へ戻る")
    XCTAssertTrue(p.render.rows[soundRow].label.contains("電紫"))
  }

  /// オフのときに案を確定すると、同時にオンへ戻る（選んだ音が鳴らないのは意図と食い違う）。
  func testApplyFamilyWhileDisabledAlsoEnables() {
    let p = model(sound: .glass, enabled: false)
    drillIn(p)
    let changes = captureChanges(p)
    p.render.selected = 4  // 気配
    p.render.onActivate()
    XCTAssertEqual(changes().map(\.id), [.notificationSound, .notificationSoundEnabled])
    XCTAssertEqual(changes().last?.value, .bool(true))
    XCTAssertTrue(p.render.rows[soundRow].label.contains("気配"))
    XCTAssertTrue(p.render.rows[soundRow + 2].label.contains("オン"))
  }

  /// 行 0「なし」の ↵ はオフにするだけで、**音案の値は触らない**（再度オンにしたら戻る）。
  func testApplyOffKeepsFamily() {
    let p = model(sound: .steel)
    drillIn(p)
    let changes = captureChanges(p)
    p.render.selected = 0
    p.render.onActivate()
    XCTAssertEqual(changes().map(\.id), [.notificationSoundEnabled])
    XCTAssertEqual(changes().first?.value, .bool(false))
    XCTAssertTrue(p.render.rows[soundRow].label.contains("なし"))
    // 潜り直すと保持している案の行に ● が戻り、確定すればまたその案で鳴る。
    drillIn(p)
    XCTAssertEqual(p.render.rows[0].label, "● なし（オフ）")
    p.render.selected = 9  // 鋼
    p.render.onActivate()
    XCTAssertTrue(p.render.rows[soundRow].label.contains("鋼"))
  }
}
