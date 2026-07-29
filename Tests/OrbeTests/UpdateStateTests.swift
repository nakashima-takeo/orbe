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

  /// トーストは時間で消えない——明示的な dismiss（✕・今すぐ再起動・変更内容）だけが下ろす。
  /// 時間経過に相当する状態イベント（再チェック・セッション終了）を挟んでも立ったまま。
  func testToastPersistsUntilExplicitDismiss() {
    let state = makeState()
    state.markReady(ready())
    XCTAssertTrue(state.toastVisible)

    state.beginCheck()
    state.settleTransientPhase()
    XCTAssertTrue(state.toastVisible, "状態イベントではトーストを下ろさない（自動消滅は存在しない）")

    state.dismissToast()
    XCTAssertFalse(state.toastVisible, "明示的な dismiss だけが下ろす")
  }

  /// トーストは readyToRestart への遷移時に一度だけ。閉じた後の再 markReady（再確認・resume）では
  /// 同一バージョンなら再表示しない（設定の状態カードには残る）。別バージョンなら再び一度だけ出る。
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

  /// バックグラウンド自動DL経路のコールバック順序で readyToRestart が維持される。
  /// ① サイレント staged（driver 経由なし・進行表示なし）: idle からの markReady 直行でトーストが立つ。
  /// ② ready 確定後の `.dismiss` 応答に続く dismissUpdateInstallation（セッション終了）が
  ///    readyToRestart とトーストを clobber しない。
  func testBackgroundStagedFlowKeepsReadyThroughSessionTeardown() {
    let state = makeState()

    // ① サイレント経路: checking/downloading を経ずに ready へ（willInstallUpdateOnQuit の写像）。
    state.markReady(ready())
    XCTAssertEqual(state.phase, .readyToRestart)
    XCTAssertTrue(state.toastVisible)

    // ② driver の後続コールバック（.dismiss 応答後の dismissUpdateInstallation）＝ settleTransientPhase。
    state.settleTransientPhase()
    XCTAssertEqual(state.phase, .readyToRestart, "セッション終了で適用待ちを idle/最新へ戻さない")
    XCTAssertTrue(state.toastVisible, "セッション終了でトーストを下ろさない")

    // resume（staged のまま再チェック）で checking→found(.installing)→dismiss と流れても維持される。
    state.dismissToast()
    state.beginCheck()
    state.markReady(ready())
    state.settleTransientPhase()
    XCTAssertEqual(state.phase, .readyToRestart)
    XCTAssertFalse(state.toastVisible, "同一プロセス内の再 ready はトーストを再表示しない")
  }

  /// 「今すぐ確認」の実行可否は既定 `.available`（fixture は全状態を注入できる）。
  /// 実行してよいのは `.available` のときだけで、`busy` と `unavailable` は同じ「押せない」でも
  /// 別の状態として保たれる（UI の名乗りが変わるため潰してはならない）。
  func testCheckAvailabilityDefaultsAvailableAndGatesCheckNow() {
    let state = makeState()
    XCTAssertEqual(state.checkAvailability, .available)
    XCTAssertTrue(state.canCheckNow)

    state.setCheckAvailability(.busy)
    XCTAssertFalse(state.canCheckNow)

    state.setCheckAvailability(.unavailable)
    XCTAssertFalse(state.canCheckNow)
    XCTAssertNotEqual(state.checkAvailability, .busy, "未起動と進行中を同じ値へ潰さない")

    state.setCheckAvailability(.available)
    XCTAssertTrue(state.canCheckNow)
  }

  /// 可否の決め方（`UpdaterService` が写す規則そのもの）。「updater が起動していない」と
  /// 「セッションが進行中」は別の値に解決する——両方を false へ潰すと、確認が走っていない
  /// dev ビルドで UI が「確認中…」を名乗ってしまう。
  func testCheckAvailabilityResolvesUnstartedApartFromBusy() {
    XCTAssertEqual(
      UpdateState.CheckAvailability.resolve(started: true, updaterCanCheck: true), .available)
    XCTAssertEqual(
      UpdateState.CheckAvailability.resolve(started: true, updaterCanCheck: false), .busy,
      "起動済みで受け付けない＝セッション進行中")
    XCTAssertEqual(
      UpdateState.CheckAvailability.resolve(started: false, updaterCanCheck: false), .unavailable,
      "未起動は進行中ではない")
    XCTAssertEqual(
      UpdateState.CheckAvailability.resolve(started: false, updaterCanCheck: true), .unavailable,
      "未起動なら Sparkle 側の可否に依らず不活性")
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
