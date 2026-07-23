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
