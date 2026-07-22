import Foundation
import XCTest

@testable import Orbe

/// アップデート状態モデルの遷移規則。とくに「トーストは readyToRestart 遷移時に
/// 1 バージョンにつき一度だけ」（見本 2a の設計注記）を固定する。
final class UpdateStateTests: XCTestCase {

  private func makeState() -> UpdateState { UpdateState(currentVersion: "0.1.0") }

  private func ready(_ version: String = "0.2.0") -> UpdateState.ReadyInfo {
    UpdateState.ReadyInfo(version: version, notes: "### 新機能\n- テスト", date: Date(), size: 13_000_000)
  }

  func testCheckingToDownloadingToReady() {
    let state = makeState()
    XCTAssertEqual(state.phase, .idle)

    state.beginCheck()
    XCTAssertEqual(state.phase, .checking)

    state.beginDownload()
    state.setExpectedLength(13_000_000)
    state.receiveData(length: 8_300_000)
    XCTAssertEqual(state.phase, .downloading(received: 8_300_000, total: 13_000_000))

    state.markReady(ready())
    XCTAssertEqual(state.phase, .readyToRestart)
    XCTAssertEqual(state.ready?.version, "0.2.0")
    XCTAssertNotNil(state.lastCheck)
  }

  func testDownloadProgressClampsToTotal() {
    let state = makeState()
    state.beginDownload()
    state.setExpectedLength(100)
    state.receiveData(length: 250)
    XCTAssertEqual(state.phase, .downloading(received: 100, total: 100))
  }

  func testUpToDateAndFailedRecordLastCheck() {
    let state = makeState()
    state.markUpToDate()
    XCTAssertEqual(state.phase, .upToDate)
    XCTAssertNotNil(state.lastCheck)

    state.fail(message: "offline")
    XCTAssertEqual(state.phase, .failed(message: "offline"))
  }

  /// トーストは readyToRestart への遷移時に一度だけ。閉じた後の再 markReady（再確認・resume）では
  /// 同一バージョンなら再表示しない。別バージョンなら再び一度だけ出る。
  func testToastShowsOncePerVersion() {
    let state = makeState()
    XCTAssertFalse(state.toastVisible)

    state.markReady(ready("0.2.0"))
    XCTAssertTrue(state.toastVisible, "readyToRestart 遷移でトーストが立つ")

    state.dismissToast()
    state.markReady(ready("0.2.0"))
    XCTAssertFalse(state.toastVisible, "同一バージョンの再 ready では再表示しない")

    state.markReady(ready("0.3.0"))
    XCTAssertTrue(state.toastVisible, "別バージョンなら再び一度だけ出る")
  }

  /// セッション終了（dismissUpdateInstallation）は進行中の見かけだけを畳み、確定状態は残す。
  func testSettleTransientPhase() {
    let state = makeState()
    state.beginCheck()
    state.settleTransientPhase()
    XCTAssertEqual(state.phase, .idle, "確認中のまま終わったら idle へ")

    state.beginDownload()
    state.settleTransientPhase()
    XCTAssertEqual(state.phase, .idle, "ready 前の DL 中断も idle へ")

    state.markReady(ready())
    state.beginDownload()  // resume 中の中断
    state.settleTransientPhase()
    XCTAssertEqual(state.phase, .readyToRestart, "適用待ちが確定済みならそこへ戻す")

    state.markUpToDate()
    state.settleTransientPhase()
    XCTAssertEqual(state.phase, .upToDate, "確定状態（最新）は畳まない")
  }

  /// トグルの didSet はバックエンドへ流れる（同値代入では流れない）。
  func testToggleCallbacksFireOnChange() {
    let state = makeState()
    var received: [Bool] = []
    state.onAutoCheckChange = { received.append($0) }

    state.autoCheck = true  // 既定と同値 → 流れない
    XCTAssertEqual(received, [])

    state.autoCheck = false
    state.autoCheck = true
    XCTAssertEqual(received, [false, true])
  }

  func testSeedLastCheckDoesNotOverwrite() {
    let state = makeState()
    let seeded = Date(timeIntervalSince1970: 1000)
    state.seedLastCheck(seeded)
    XCTAssertEqual(state.lastCheck, seeded)

    state.markUpToDate(at: Date(timeIntervalSince1970: 2000))
    state.seedLastCheck(Date(timeIntervalSince1970: 3000))
    XCTAssertEqual(state.lastCheck, Date(timeIntervalSince1970: 2000), "確定済みの最終確認は seed で上書きしない")
  }
}

/// 設定パレットのアップデートセクション（root 行・ドリルイン・トグル・今すぐ確認の配線）。
@MainActor
final class SettingsPaletteUpdateTests: XCTestCase {

  private func makePalette(update: UpdateState?) -> SettingsPaletteModel {
    SettingsPaletteModel(
      values: ScopedSettingsValues(global: SettingsLayer(), override: SettingsLayer()),
      fontNames: [], agents: [], localization: LocalizationStore(language: .ja), update: update)
  }

  func testRootRowAbsentWithoutUpdateState() {
    let palette = makePalette(update: nil)
    XCTAssertFalse(palette.render.rows.contains { $0.label.hasPrefix("アップデート") })
  }

  func testRootRowPresentAndDrillIn() {
    let update = UpdateState(currentVersion: "0.1.0")
    let palette = makePalette(update: update)
    guard let row = palette.render.rows.lastIndex(where: { $0.label.hasPrefix("アップデート") })
    else {
      return XCTFail("root にアップデート行が無い")
    }
    XCTAssertTrue(palette.render.rows[row].label.contains("v0.1.0"), "root 行は現在バージョンを名乗る")

    palette.render.selected = row
    palette.activate()  // ドリルイン
    XCTAssertEqual(palette.render.breadcrumb, "‹ アップデート")
    XCTAssertEqual(palette.render.rows.count, 6, "状態カード・バージョン・トグル3種・今すぐ確認")
    XCTAssertFalse(palette.render.rows[1].enabled, "バージョン行は情報行")
  }

  func testToggleRowsFlipStateAndCheckNowFires() {
    let update = UpdateState(currentVersion: "0.1.0")
    var checked = 0
    update.onCheckNow = { checked += 1 }
    let palette = makePalette(update: update)
    palette.drillIntoUpdate()

    palette.render.selected = 2  // 自動確認
    palette.activate()
    XCTAssertFalse(update.autoCheck)
    palette.activate()
    XCTAssertTrue(update.autoCheck)

    palette.render.selected = 4  // 終了時自動適用
    palette.activate()
    XCTAssertFalse(update.autoInstallOnQuit)

    palette.render.selected = 5  // 今すぐ確認
    palette.activate()
    XCTAssertEqual(checked, 1)
  }

  func testStatusRowPrimaryActionByPhase() {
    let update = UpdateState(currentVersion: "0.1.0")
    var restarted = 0
    var checked = 0
    update.onRestartNow = { restarted += 1 }
    update.onCheckNow = { checked += 1 }
    let palette = makePalette(update: update)
    palette.drillIntoUpdate()
    palette.render.selected = 0

    palette.activate()  // idle → no-op
    XCTAssertEqual(restarted + checked, 0)

    update.fail(message: "offline")
    palette.activate()  // 失敗 → 再試行（今すぐ確認と同じ導線）
    XCTAssertEqual(checked, 1)

    update.markReady(
      UpdateState.ReadyInfo(version: "0.2.0", notes: nil, date: nil, size: 0))
    palette.activate()  // 適用待ち → 今すぐ再起動
    XCTAssertEqual(restarted, 1)
  }
}
