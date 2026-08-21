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

  // MARK: - 設定サブの行の構成

  /// 3 行（完了の音源 / 入力待ちの音源 / 同一化トグル）。値を選ぶ面ではないので ● は持たない。
  func testCustomSubRows() {
    let p = model(customDone: source("a.wav", "chime.mp3"))
    drillIntoCustom(p)
    XCTAssertEqual(p.render.breadcrumb, "‹ カスタム")
    XCTAssertFalse(p.render.fieldVisible)
    XCTAssertEqual(p.render.rows.count, 3)
    XCTAssertEqual(p.render.rows[0].label, "完了の音源  chime.mp3")
    XCTAssertEqual(p.render.rows[2].label, "入力待ちも完了と同じ音  オン")
    XCTAssertTrue(p.render.rows.allSatisfy { !$0.label.hasPrefix("● ") }, "フォーム面に ● は無い")
    XCTAssertEqual(p.render.selected, 0, "入場は先頭行")
  }

  /// 同一化トグルが on の間、入力待ちの行は無効行で「（完了と同じ）」を示す（押しても効かない行にしない）。
  func testWaitingRowIsDisabledWhileSameAsDone() {
    let p = model(customDone: source("a.wav", "chime.mp3"))
    drillIntoCustom(p)
    XCTAssertEqual(p.render.rows[1].label, "入力待ちの音源  （完了と同じ）")
    XCTAssertFalse(p.render.rows[1].enabled)
    XCTAssertFalse(p.render.rows[1].chevron)
    // ↓ で入力待ち行を飛ばしてトグル行へ着く。
    p.render.onDown()
    XCTAssertEqual(p.render.selected, 2)
  }

  /// トグルを off にすると入力待ちの行が生き、その音源（未設定なら「未設定」）を出す。
  func testWaitingRowBecomesEditableWhenToggleOff() {
    let p = model(
      customDone: source("a.wav", "d.mp3"), customWaiting: source("b.wav", "w.mp3"),
      waitingSameAsDone: false)
    drillIntoCustom(p)
    XCTAssertEqual(p.render.rows[1].label, "入力待ちの音源  w.mp3")
    XCTAssertTrue(p.render.rows[1].enabled)
    XCTAssertEqual(p.render.rows[2].label, "入力待ちも完了と同じ音  オフ")

    let unset = model(customDone: source("a.wav", "d.mp3"), waitingSameAsDone: false)
    drillIntoCustom(unset)
    XCTAssertEqual(unset.render.rows[1].label, "入力待ちの音源  未設定")
  }

  // MARK: - 同一化トグル

  /// `↵` と `→` のどちらでも反転し、その場で行の表示が追従する（選択は動かない）。
  func testToggleFlipsOnEnterAndRightArrow() {
    let p = model()
    drillIntoCustom(p)
    let changes = captureChanges(p)
    p.render.selected = 2
    p.render.onActivate()
    XCTAssertEqual(changes().map(\.id), [.notificationSoundCustomWaitingSameAsDone])
    XCTAssertEqual(changes().last?.value, .bool(false))
    XCTAssertEqual(p.render.rows[2].label, "入力待ちも完了と同じ音  オフ")
    XCTAssertEqual(p.render.selected, 2, "選択はトグル行に留まる")
    XCTAssertTrue(p.render.onRight())
    XCTAssertEqual(changes().last?.value, .bool(true), "→ も同じ反転")
  }

  // MARK: - 取り込み（seam 経由）

  /// 音源行の `↵` はファイル選択を開き、選ばれたファイルを取り込んで現在スコープへ書く。
  /// 成功したらその音を実効音量で 1 回鳴らし、その行に EQ を出す。
  func testImportWritesTheValueAndPlaysItBack() {
    let p = model(volume: 40)
    drillIntoCustom(p)
    let changes = captureChanges(p)
    let previews = capturePreviews(p)
    p.schedulePreviewEnd = { _, _ in }
    let calls = stubPicker(p, returns: URL(fileURLWithPath: "/tmp/chime.mp3"))
    p.importSoundFile = { _ in .success(self.source("new.wav", "chime.mp3", duration: 2.5)) }

    p.render.onActivate()  // 行 0＝完了の音源
    XCTAssertEqual(calls(), 1)
    XCTAssertEqual(changes().map(\.id), [.notificationSoundCustomDone])
    XCTAssertEqual(p.render.rows[0].label, "完了の音源  chime.mp3", "行の表示が追従する")
    XCTAssertEqual(
      previews(), [Preview(source: .imported(file: "new.wav"), event: .done, volume: 40)],
      "取り込んだ結果を実効音量で 1 回鳴らす")
    XCTAssertEqual(p.render.rowAccessory?.row, 0, "その行に EQ が出る")
  }

  /// 入力待ちの行の取り込みは waiting のキーへ書き、waiting として鳴らす。
  func testImportIntoTheWaitingRow() {
    let p = model(waitingSameAsDone: false)
    drillIntoCustom(p)
    let changes = captureChanges(p)
    let previews = capturePreviews(p)
    p.schedulePreviewEnd = { _, _ in }
    _ = stubPicker(p, returns: URL(fileURLWithPath: "/tmp/w.mp3"))
    p.importSoundFile = { _ in .success(self.source("w.wav", "w.mp3")) }

    p.render.selected = 1
    p.render.onActivate()
    XCTAssertEqual(changes().map(\.id), [.notificationSoundCustomWaiting])
    XCTAssertEqual(previews().last?.event, .waiting)
  }

  /// キャンセル（パネルを閉じた）は no-op——値も書かず、鳴らさず、理由も出さない。
  func testCancelledPickIsNoOp() {
    let p = model()
    drillIntoCustom(p)
    let changes = captureChanges(p)
    let previews = capturePreviews(p)
    let calls = stubPicker(p, returns: nil)
    var imported = 0
    p.importSoundFile = { _ in
      imported += 1
      return .success(self.source("x.wav", "x.mp3"))
    }

    p.render.onActivate()
    XCTAssertEqual(calls(), 1)
    XCTAssertEqual(imported, 0, "選ばれていないので取り込まない")
    XCTAssertTrue(changes().isEmpty)
    XCTAssertTrue(previews().isEmpty)
    XCTAssertEqual(p.render.rows.count, 3, "理由行は出ない")
  }

  /// 取り込み失敗は面の先頭に理由 1 行（選択不可）で出て、値は書かれない。行の意味はずれない。
  func testImportFailureShowsANoticeAndWritesNothing() {
    for (error, expected) in [
      (SoundFileImporter.ImportError.unreadable, "読み込めない形式です（broken.mp3）"),
      (.silent, "音が入っていません（broken.mp3）"),
    ] {
      let p = model()
      drillIntoCustom(p)
      let changes = captureChanges(p)
      let previews = capturePreviews(p)
      _ = stubPicker(p, returns: URL(fileURLWithPath: "/tmp/broken.mp3"))
      p.importSoundFile = { _ in .failure(error) }

      p.render.onActivate()
      XCTAssertEqual(p.render.rows.count, 4, "理由行が 1 行増える")
      XCTAssertEqual(p.render.rows[0].label, expected)
      XCTAssertFalse(p.render.rows[0].enabled)
      XCTAssertEqual(p.render.rows[1].label, "完了の音源  未設定", "音源行は未設定のまま")
      XCTAssertEqual(p.render.selected, 1, "選択は操作した行のまま（理由行のぶんずれる）")
      XCTAssertTrue(changes().isEmpty)
      XCTAssertTrue(previews().isEmpty, "失敗したものは鳴らさない")
    }
  }

  /// 理由行が出ている状態でも、行の意味は index でなく種別で決まる（トグル行はトグルのまま）。
  func testRowsKeepTheirMeaningWhileTheNoticeIsShown() {
    let p = model()
    drillIntoCustom(p)
    _ = stubPicker(p, returns: URL(fileURLWithPath: "/tmp/broken.mp3"))
    p.importSoundFile = { _ in .failure(.unreadable) }
    p.render.onActivate()
    let changes = captureChanges(p)

    p.render.selected = 3  // 理由行 1 + トグル行 2
    p.render.onActivate()
    XCTAssertEqual(changes().map(\.id), [.notificationSoundCustomWaitingSameAsDone])
    XCTAssertEqual(p.render.rows.count, 3, "次の操作で理由行は消える")
  }

  /// 理由は面を離れると消える（次に潜り直したとき持ち越さない）。
  func testNoticeClearsOnLeavingTheFace() {
    let p = model()
    drillIntoCustom(p)
    _ = stubPicker(p, returns: URL(fileURLWithPath: "/tmp/broken.mp3"))
    p.importSoundFile = { _ in .failure(.unreadable) }
    p.render.onActivate()
    XCTAssertEqual(p.render.rows.count, 4)

    p.render.onLeft()  // 通知音サブへ
    _ = p.render.onRight()  // 潜り直す
    XCTAssertEqual(p.render.rows.count, 3)
  }

  // MARK: - workspace スコープ

  /// workspace スコープの取り込みは上書き層へ書き、root では delete で継承へ戻せる。
  func testWorkspaceScopeWritesTheOverrideAndDeleteClearsIt() {
    var override = SettingsLayer()
    override[SettingKeys.notificationSoundCustomDone] = source("ws.wav", "ws.mp3")
    let p = model(
      customDone: source("global.wav", "global.mp3"), scope: .workspace, override: override)
    drillIntoCustom(p)
    XCTAssertEqual(p.render.rows[0].label, "完了の音源  ws.mp3", "実効値は上書き層")

    var applied: [(SettingChange, SettingsScope)] = []
    p.onApply = { applied.append(($0, $1)) }
    _ = stubPicker(p, returns: URL(fileURLWithPath: "/tmp/next.mp3"))
    p.importSoundFile = { _ in .success(self.source("next.wav", "next.mp3")) }
    p.schedulePreviewEnd = { _, _ in }
    p.render.onActivate()
    XCTAssertEqual(applied.last?.1, .workspace, "書き先は上書き層")

    // 上書きを解除すれば global を継承する。
    p.assign(p.values.clearChange(for: .notificationSoundCustomDone))
    p.rebuild()
    XCTAssertEqual(p.render.rows[0].label, "完了の音源  global.mp3")
  }
}
