import OrbeSound
import XCTest

@testable import Orbe

/// カスタム音源まわり——通知音サブ末尾の「カスタム」行と、その 1 段奥の設定サブ。
/// ファイル選択と取り込みは seam（`pickSoundFile` / `importSoundFile`）へ差し替えて測る
/// ——テストは実ダイアログも実 IO も触らない。
@MainActor
extension SettingsPaletteSoundTests {
  /// 通知音サブ → カスタム行 → 設定サブ。
  func drillIntoCustom(_ p: SettingsPaletteModel) {
    drillIn(p)
    p.render.selected = customRow
    _ = p.render.onRight()
  }

  /// ファイル選択の seam。呼ばれた回数と、返す URL を握る。
  func stubPicker(_ p: SettingsPaletteModel, returns url: URL?) -> () -> Int {
    var calls = 0
    p.pickSoundFile = {
      calls += 1
      return url
    }
    return { calls }
  }

  // MARK: - カスタム行（通知音サブの末尾）
  /// カスタム行の補足は実効の完了音源の表示名。未設定なら「未設定」。
  func testCustomRowDetailShowsTheEffectiveDoneSourceName() {
    let unset = model()
    drillIn(unset)
    XCTAssertEqual(unset.render.rows[customRow].detail, "未設定")

    let configured = model(customDone: source("a.wav", "chime.mp3"))
    drillIn(configured)
    XCTAssertEqual(configured.render.rows[customRow].detail, "chime.mp3")
  }

  /// カスタムを選んでいるときは ● と初期ハイライトがカスタム行に乗る（案の行には乗らない）。
  func testCustomRowCarriesTheMarkerWhenSelected() {
    let p = model(sound: .custom, customDone: source("a.wav", "chime.mp3"))
    drillIn(p)
    XCTAssertEqual(p.render.rows[customRow].label, "● カスタム")
    XCTAssertEqual(p.render.selected, customRow)
    XCTAssertEqual(p.render.rows.filter { $0.label.hasPrefix("● ") }.count, 1)
  }

  /// オフのときはカスタム選択中でも ● は行 0（鳴らない設定が鳴りそうに読めない）。
  func testCustomSelectionStillMarksOffRowWhenDisabled() {
    let p = model(sound: .custom, enabled: false, customDone: source("a.wav", "chime.mp3"))
    drillIn(p)
    XCTAssertEqual(p.render.rows[0].label, "● なし（オフ）")
    XCTAssertEqual(p.render.selected, 0)
  }

  /// root の通知音行の値表示はカスタム選択で「カスタム」（オフのときは従来どおり「なし」）。
  func testRootShowsCustomVocabulary() {
    let p = model(sound: .custom, customDone: source("a.wav", "chime.mp3"))
    XCTAssertTrue(p.render.rows[soundRow].label.contains("カスタム"))
    let off = model(sound: .custom, enabled: false, customDone: source("a.wav", "chime.mp3"))
    XCTAssertTrue(off.render.rows[soundRow].label.contains("なし"))
    XCTAssertFalse(off.render.rows[soundRow].label.contains("カスタム"))
  }

  /// カスタム行の試聴は**確定後と同じ解決**で鳴る（トグル on の入力待ちは完了の音源）。
  func testCustomRowPreviewsTheResolvedSource() {
    let p = model(customDone: source("done.wav", "done.mp3"))
    let previews = capturePreviews(p)
    let changes = captureChanges(p)
    drillIn(p)
    p.render.selected = customRow
    XCTAssertEqual(previews().last?.source, .imported(file: "done.wav"))
    XCTAssertEqual(previews().last?.event, .done)
    _ = p.render.onTab()  // 入力待ちへ（同一化トグルは既定オン）
    XCTAssertEqual(previews().last?.source, .imported(file: "done.wav"), "トグル on なら完了の音源")
    XCTAssertEqual(previews().last?.event, .waiting)
    XCTAssertTrue(changes().isEmpty, "試聴は設定を書かない")
  }

  /// 同一化トグルが off なら、入力待ちの試聴は入力待ちの音源になる。
  func testCustomRowPreviewFollowsTheWaitingSourceWhenToggleOff() {
    let p = model(
      customDone: source("done.wav", "d.mp3"), customWaiting: source("waiting.wav", "w.mp3"),
      waitingSameAsDone: false)
    let previews = capturePreviews(p)
    drillIn(p)
    p.render.selected = customRow
    _ = p.render.onTab()
    XCTAssertEqual(previews().last?.source, .imported(file: "waiting.wav"))
  }

  /// 片方だけ未設定なら、その event は紋章の**同 event** 音へ落ちて鳴る（黙らない）。
  func testCustomRowPreviewFallsBackOnTheSameEvent() {
    let p = model(customWaiting: source("waiting.wav", "w.mp3"), waitingSameAsDone: false)
    let previews = capturePreviews(p)
    drillIn(p)
    p.render.selected = customRow
    XCTAssertEqual(previews().last?.source, .synth(NotificationSound.default), "完了は未設定")
    XCTAssertEqual(previews().last?.event, .done)
  }

  /// 完全未構成（完了も入力待ちも未設定）では解除行と同じく鳴らさない——EQ も出ない。
  func testCustomRowIsSilentWhenNothingIsImported() {
    let p = model()
    let previews = capturePreviews(p)
    drillIn(p)
    p.render.selected = customRow
    XCTAssertEqual(previews().count, 1)
    XCTAssertNil(previews().last?.source ?? nil, "鳴らさず止めるだけ")
    XCTAssertNil(p.render.rowAccessory, "EQ も出ない")
  }

  /// EQ の点灯時間は取り込み時に測った長さ（案の合成長ではない）。
  func testCustomRowIndicatorUsesTheImportedDuration() {
    let p = model(customDone: source("done.wav", "d.mp3", duration: 4.25))
    var delays: [TimeInterval] = []
    p.schedulePreviewEnd = { delay, _ in delays.append(delay) }
    drillIn(p)
    p.render.selected = customRow
    XCTAssertEqual(delays.last, 4.25)
  }

  /// 入力待ちだけ取り込んだ状態でも ↵ は確定する——その行は現に取り込んだ音を鳴らしており、
  /// 「鳴るのに選べない」行を作らないため（試聴と確定は同じ 1 つの述語で判定する）。
  func testCustomRowEnterConfirmsWhenOnlyWaitingIsImported() {
    let p = model(customWaiting: source("waiting.wav", "w.mp3"), waitingSameAsDone: false)
    drillIn(p)
    let changes = captureChanges(p)
    p.render.selected = customRow
    p.render.onActivate()
    XCTAssertEqual(changes().map(\.id), [.notificationSound])
    XCTAssertEqual(changes().first?.value, .string("custom"))
    XCTAssertNil(p.render.breadcrumb, "root へ戻る")
  }

  /// 同一化トグルが on で完了が未設定なら、入力待ちを取り込んでいてもどの event も紋章へ落ちる
  /// ——鳴らせる取り込み音が無いので、試聴は黙り ↵ はドリルになる。
  func testCustomRowIsSilentWhenTheToggleHidesTheOnlyImport() {
    let p = model(customWaiting: source("waiting.wav", "w.mp3"), waitingSameAsDone: true)
    let previews = capturePreviews(p)
    let changes = captureChanges(p)
    drillIn(p)
    p.render.selected = customRow
    XCTAssertNil(previews().last?.source ?? nil, "紋章しか鳴らないなら鳴らさない")
    XCTAssertNil(p.render.rowAccessory, "EQ も出ない")
    p.render.onActivate()
    XCTAssertEqual(p.render.breadcrumb, "‹ カスタム", "確定でなく潜る")
    XCTAssertTrue(changes().isEmpty)
  }

  /// 未設定のときのカスタム行 ↵ は確定でなくドリル（確定しても鳴らせる音が無い状態を作らない）。
  func testCustomRowEnterDrillsInWhenNothingIsImported() {
    let p = model()
    let changes = captureChanges(p)
    drillIn(p)
    p.render.selected = customRow
    p.render.onActivate()
    XCTAssertEqual(p.render.breadcrumb, "‹ カスタム")
    XCTAssertTrue(changes().isEmpty, "潜るだけで値は書かない")
  }

  /// 設定済みならカスタム行の ↵ は確定（オフだったなら同時にオンへ戻る）。
  func testCustomRowEnterConfirmsWhenConfigured() {
    let p = model(sound: .preset(.glass), enabled: false, customDone: source("a.wav", "chime.mp3"))
    drillIn(p)
    let changes = captureChanges(p)
    p.render.selected = customRow
    p.render.onActivate()
    XCTAssertEqual(changes().map(\.id), [.notificationSound, .notificationSoundEnabled])
    XCTAssertEqual(changes().first?.value, .string("custom"))
    XCTAssertNil(p.render.breadcrumb, "root へ戻る")
    XCTAssertTrue(p.render.rows[soundRow].label.contains("カスタム"))
  }

  /// `→` は「潜る」意味だけを持つ——案の行では効かず、カスタム行だけが 1 段深く潜る。
  func testRightArrowOnlyDrillsFromTheCustomRow() {
    let p = model(customDone: source("a.wav", "chime.mp3"))
    drillIn(p)
    p.render.selected = 3  // 案の行
    XCTAssertFalse(p.render.onRight())
    XCTAssertEqual(p.render.breadcrumb, "‹ 通知音", "案の行では潜らない")
    p.render.selected = customRow
    XCTAssertTrue(p.render.onRight())
    XCTAssertEqual(p.render.breadcrumb, "‹ カスタム")
  }

  /// `←`/`Esc` は 1 段ずつ浅くなり、カスタム行へ選択が復元される。
  func testReturningFromCustomRestoresTheCustomRow() {
    let p = model()
    drillIn(p)
    p.render.selected = customRow
    _ = p.render.onRight()
    p.render.onLeft()
    XCTAssertEqual(p.render.breadcrumb, "‹ 通知音", "root でなく通知音サブへ 1 段戻る")
    XCTAssertEqual(p.render.selected, customRow)
    _ = p.render.onRight()
    p.render.onEscape()
    XCTAssertEqual(p.render.breadcrumb, "‹ 通知音")
    XCTAssertEqual(p.render.selected, customRow)
  }
}
