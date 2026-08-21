import OrbeSound
import XCTest

@testable import Orbe

/// カスタム音源の**設定サブ**（通知音サブの 1 段奥）——固定 3 行の構成・同一化トグル・
/// seam 経由の取り込み・workspace スコープ。カスタム**行**そのものは `+Custom` が測る。
@MainActor
extension SettingsPaletteSoundTests {
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

  /// 理由行が出ている状態からのキャンセルでも、選択は押した行の**種別**に留まる。
  /// 理由行が消えると行 index の意味が 1 つ繰り上がるので、ここで置き直しを落とすと選択が
  /// 別の行（同一化トグル on なら押せないはずの行）へ移り、次の ↵ が違う設定キーを書く。
  func testCancelAfterAFailureKeepsTheSelectedRowKind() {
    let p = model()
    drillIntoCustom(p)
    _ = stubPicker(p, returns: URL(fileURLWithPath: "/tmp/broken.mp3"))
    p.importSoundFile = { _ in .failure(.unreadable) }
    p.render.onActivate()
    XCTAssertEqual(p.render.rows.count, 4, "前提: 理由行が出ている")
    XCTAssertEqual(p.soundCustomRow(at: p.render.selected), .doneSource)

    _ = stubPicker(p, returns: nil)  // やり直して思い直す
    p.render.onActivate()
    XCTAssertEqual(p.render.rows.count, 3, "理由行は消える")
    XCTAssertEqual(p.soundCustomRow(at: p.render.selected), .doneSource, "選択は完了の音源のまま")
  }

  /// 取り込み失敗は面の先頭に理由 1 行（選択不可）で出て、値は書かれない。行の意味はずれない。
  func testImportFailureShowsANoticeAndWritesNothing() {
    for (error, expected) in [
      (SoundFileImporter.ImportError.unreadable, "読み込めない形式です（broken.mp3）"),
      (.silent, "音が入っていません（broken.mp3）"),
      // 壊れているのはアプリの保存先なので、選んだファイルを名指ししない。
      (.storageFailed, "音源を保存できませんでした"),
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

  /// workspace スコープの取り込みは上書き層へ書く。
  ///
  /// 上書きの解除はこの面のキー操作には無い（カスタム音源は root に行を持たず、`delete` は root 専用）。
  /// 末尾で `clearChange` を直に叩いているのは**モデル API レベルの確認**で、キー経路の代役ではない
  /// ——パレットからの解除経路は現状 `orb config unset` だけ（→ spec/palette/settings）。
  func testWorkspaceScopeWritesTheOverride() {
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
