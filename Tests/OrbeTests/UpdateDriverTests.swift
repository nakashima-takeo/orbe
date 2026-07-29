import Sparkle
import XCTest

@testable import Orbe

/// Sparkle 実体（driver / delegate）と UpdateState の接続規則。
/// バックグラウンド自動DL経路は user driver を通らず delegate（willInstallUpdateOnQuit）だけが
/// 通知を受ける——その写像と、driver の応答ポリシー・セッション終了時の状態維持を固定する。
@MainActor
final class UpdateDriverTests: XCTestCase {

  private func makeState() -> UpdateState { UpdateState(currentVersion: "0.1.0") }

  /// サイレント staged の delegate 通知が readyToRestart＋トーストに写像され、YES（即時適用ハンドラを
  /// 預かる）を返す。「今すぐ再起動」は預かったハンドラを呼ぶ（re-check の遠回りをしない）。
  func testWillInstallUpdateOnQuitMapsToReadyAndKeepsImmediateHandler() {
    let service = UpdaterService()
    var installed = 0
    // delegate 実装は第1引数の updater を参照せず self.state だけを触るため、SPUUpdater は
    // 必須引数を満たすためのダミー（渡す driver / state は結果に影響しない）。
    let handled = service.updater(
      SPUUpdater(
        hostBundle: .main, applicationBundle: .main,
        userDriver: UpdateUserDriver(state: makeState()), delegate: nil),
      willInstallUpdateOnQuit: SUAppcastItem.empty(),
      immediateInstallationBlock: { installed += 1 })

    XCTAssertTrue(handled, "YES＝即時適用ハンドラを預かり、pending 中の再チェックも止める")
    XCTAssertEqual(service.state.phase, .readyToRestart)
    XCTAssertTrue(service.state.toastVisible, "サイレント staged でもトーストは一度立つ")

    service.installAndRelaunch()
    XCTAssertEqual(installed, 1, "「今すぐ再起動」は預かった即時適用ハンドラを呼ぶ")
  }

  /// driver の ready 応答ポリシー: 終了時自動適用オンは `.dismiss` 即応答（＝Sparkle が終了時に適用）、
  /// その後のセッション終了（dismissUpdateInstallation）でも readyToRestart を維持する。
  func testDriverReadyDismissReplyThenTeardownKeepsReady() {
    let state = makeState()
    let driver = UpdateUserDriver(state: state)
    state.markReady(UpdateState.ReadyInfo(version: "0.2.0", notes: nil, date: nil, size: 0))

    var choices: [SPUUserUpdateChoice] = []
    driver.showReady { choices.append($0) }
    XCTAssertEqual(choices, [.dismiss], "自動適用オンは保留せず dismiss（終了時適用）を即応答する")

    driver.dismissUpdateInstallation()
    XCTAssertEqual(state.phase, .readyToRestart, "セッション終了が適用待ちを clobber しない")
  }

  /// 終了時自動適用オフ: ready の reply は保留され、「今すぐ再起動」だけが `.install` を返す。
  func testDriverReadyHoldsReplyWhenAutoInstallOff() {
    let state = makeState()
    state.autoInstallOnQuit = false
    let driver = UpdateUserDriver(state: state)
    state.markReady(UpdateState.ReadyInfo(version: "0.2.0", notes: nil, date: nil, size: 0))

    var choices: [SPUUserUpdateChoice] = []
    driver.showReady { choices.append($0) }
    XCTAssertEqual(choices, [], "オフのときは reply を保留する（再起動ボタンからのみ）")

    XCTAssertTrue(driver.consumePendingInstallReply())
    XCTAssertEqual(choices, [.install])
  }

  /// 終了確認をキャンセルした（アプリが終了要求に応じなかった）セッションの再送ハンドラは、
  /// 呼んだ後も保持され何度でも送り直せる——「今すぐ再起動」を押し直せば終了確認が再び出る。
  func testRetryTerminationResendsRepeatedly() {
    let driver = UpdateUserDriver(state: makeState())
    XCTAssertFalse(driver.retryTermination(), "終了要求を待つセッションが無ければ再送しない")

    var retried = 0
    driver.showInstallingUpdate(
      withApplicationTerminated: false, retryTerminatingApplication: { retried += 1 })

    XCTAssertTrue(driver.retryTermination())
    XCTAssertEqual(retried, 1)
    XCTAssertTrue(driver.retryTermination(), "呼んでも破棄しない（SPUUserDriver.h: 複数回呼んでよい）")
    XCTAssertEqual(retried, 2)
  }

  /// アプリが既に終了しているときの再送ハンドラは呼んではならないため保持しない。
  func testRetryTerminationNotHeldWhenApplicationTerminated() {
    let driver = UpdateUserDriver(state: makeState())
    driver.showInstallingUpdate(
      withApplicationTerminated: true, retryTerminatingApplication: { XCTFail("呼んではならない") })

    XCTAssertFalse(driver.retryTermination())
  }

  /// 再送ハンドラはセッション限り。セッション終了後は死んだハンドラを呼ばない。
  func testRetryTerminationDroppedOnSessionTeardown() {
    let driver = UpdateUserDriver(state: makeState())
    driver.showInstallingUpdate(
      withApplicationTerminated: false, retryTerminatingApplication: { XCTFail("セッション終了後に呼ばない") })

    driver.dismissUpdateInstallation()
    XCTAssertFalse(driver.retryTermination())
  }

  /// 「今すぐ再起動」は終了要求の再送を即時適用ハンドラより優先する——再送ハンドラが立つのは
  /// 生きたセッションが終了を待つ間だけで、そこで即時適用へ回すと同じ更新へ二重の要求を出す。
  func testInstallAndRelaunchPrefersRetryTerminationOverImmediateInstall() {
    let service = UpdaterService()
    var installed = 0
    var retried = 0
    _ = service.updater(
      SPUUpdater(
        hostBundle: .main, applicationBundle: .main,
        userDriver: UpdateUserDriver(state: makeState()), delegate: nil),
      willInstallUpdateOnQuit: SUAppcastItem.empty(),
      immediateInstallationBlock: { installed += 1 })
    service.driver.showInstallingUpdate(
      withApplicationTerminated: false, retryTerminatingApplication: { retried += 1 })

    service.installAndRelaunch()
    XCTAssertEqual(retried, 1, "終了要求の再送が最優先")
    XCTAssertEqual(installed, 0, "即時適用ハンドラは呼ばない（二重要求を出さない）")
  }

  /// サイレント経路は user driver を通らない＝dismissUpdateInstallation が来ないため、
  /// willInstallUpdateOnQuit が「今すぐ再起動」要求の終端になる。要求は消費されて即時適用へ繋がる。
  func testWillInstallUpdateOnQuitConsumesPendingInstallRequest() {
    let service = UpdaterService()
    service.driver.installRequested = true

    let installed = expectation(description: "預かった直後の即時適用")
    _ = service.updater(
      SPUUpdater(
        hostBundle: .main, applicationBundle: .main,
        userDriver: UpdateUserDriver(state: makeState()), delegate: nil),
      willInstallUpdateOnQuit: SUAppcastItem.empty(),
      immediateInstallationBlock: { installed.fulfill() })

    XCTAssertFalse(service.driver.installRequested, "要求は消費して残さない")
    wait(for: [installed], timeout: 1)
  }
}
