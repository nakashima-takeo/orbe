import Foundation
import XCTest

@testable import Orbe

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

  /// 確認を受け付けられない間（セッション進行中）は「今すぐ確認」の ↵ が走らない。
  /// 行は「確認中…」か減光で表示され、押しても走らないことは画面から読める。
  func testCheckNowDoesNotFireWhileCheckUnavailable() {
    let update = UpdateState(currentVersion: "0.1.0")
    var checked = 0
    update.onCheckNow = { checked += 1 }
    update.setCheckAvailability(.busy)
    let palette = makePalette(update: update)
    palette.drillIntoUpdate()

    palette.render.selected = 5  // 今すぐ確認
    palette.activate()
    XCTAssertEqual(checked, 0)

    update.setCheckAvailability(.unavailable)
    palette.activate()
    XCTAssertEqual(checked, 0, "updater が動いていないときも走らない")

    update.setCheckAvailability(.available)
    palette.activate()
    XCTAssertEqual(checked, 1, "受け付けられるようになれば走る")
  }

  /// 失敗カードの「再試行」は「今すぐ確認」と同じ導線＝同じ可否に従う。
  /// 受け付けられない間に ↵ しても走らない（ボタンも disabled で減光する）。
  func testFailedCardRetryFollowsCheckAvailability() {
    let update = UpdateState(currentVersion: "0.1.0")
    var checked = 0
    update.onCheckNow = { checked += 1 }
    update.fail(message: "offline")
    let palette = makePalette(update: update)
    palette.drillIntoUpdate()
    palette.render.selected = 0  // 状態カード

    update.setCheckAvailability(.busy)
    palette.activate()
    XCTAssertEqual(checked, 0, "セッション進行中は再試行も走らない")

    update.setCheckAvailability(.unavailable)
    palette.activate()
    XCTAssertEqual(checked, 0, "updater が動いていないときも走らない")

    update.setCheckAvailability(.available)
    palette.activate()
    XCTAssertEqual(checked, 1)
  }

  /// 「今すぐ確認」行の 3 態。**updater が動いていないとき（`.unavailable`）に「確認中…」を
  /// 名乗らない**ことが要点——確認は走っていないので、名乗れば嘘になる。
  func testCheckNowRowAppearanceNeverClaimsCheckingWhenUnavailable() {
    let update = UpdateState(currentVersion: "0.1.0")
    XCTAssertEqual(UpdateCheckNowAppearance.resolve(update), .actionable)

    update.setCheckAvailability(.unavailable)
    XCTAssertEqual(
      UpdateCheckNowAppearance.resolve(update), .dimmed, "未起動は減光のみ（確認中を名乗らない）")

    // 背景の定期確認中は phase が idle のまま。カードは「まだ確認していません」に留まり、
    // 進行中の確認を語るのはここだけ（事実そのとおり走っている）。
    update.setCheckAvailability(.busy)
    XCTAssertEqual(UpdateCheckNowAppearance.resolve(update), .checking)

    // 状態カードが理由を語る間は減光に留める。
    update.beginDownload(version: "0.2.0")
    XCTAssertEqual(UpdateCheckNowAppearance.resolve(update), .dimmed)
    update.markReady(UpdateState.ReadyInfo(version: "0.2.0", notes: nil, date: nil, size: 0))
    XCTAssertEqual(UpdateCheckNowAppearance.resolve(update), .dimmed)

    // 自分の確認が走っている間は可否に依らずスピナー（fixture が .checking を注入しても同じ）。
    update.beginCheck()
    update.setCheckAvailability(.available)
    XCTAssertEqual(UpdateCheckNowAppearance.resolve(update), .checking)
  }

  /// 一度も確認していない状態を「最新です」と名乗らせない。updater が動いていないビルドは
  /// 確認そのものが走らないので、さらに「確認しない」と言い分ける。
  func testIdleCardNeverClaimsUpToDate() {
    XCTAssertEqual(UpdateIdleAppearance.resolve(.available), .notChecked)
    XCTAssertEqual(UpdateIdleAppearance.resolve(.busy), .notChecked)
    XCTAssertEqual(UpdateIdleAppearance.resolve(.unavailable), .checkDisabled)
    XCTAssertNotEqual(UpdateIdleAppearance.notChecked.label, .updateStateUpToDate)
    XCTAssertNotEqual(UpdateIdleAppearance.checkDisabled.label, .updateStateUpToDate)
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
