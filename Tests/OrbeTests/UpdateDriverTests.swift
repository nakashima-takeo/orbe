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

    XCTAssertTrue(driver.hasPendingInstallReply)
    driver.consumePendingInstallReply()
    XCTAssertEqual(choices, [.install])
    XCTAssertFalse(driver.hasPendingInstallReply, "消費したら残さない")
  }

  /// 終了確認をキャンセルした（アプリが終了要求に応じなかった）セッションの再送ハンドラは、
  /// 呼んだ後も保持され何度でも送り直せる——「今すぐ再起動」を押し直せば終了確認が再び出る。
  func testRetryTerminationResendsRepeatedly() {
    let driver = UpdateUserDriver(state: makeState())
    XCTAssertFalse(driver.hasRetryTermination, "終了要求を待つセッションが無ければ再送先も無い")

    var retried = 0
    driver.showInstallingUpdate(
      withApplicationTerminated: false, retryTerminatingApplication: { retried += 1 })

    XCTAssertTrue(driver.hasRetryTermination)
    driver.retryTermination()
    XCTAssertEqual(retried, 1)
    driver.retryTermination()
    XCTAssertEqual(retried, 2, "呼んでも破棄しない（SPUUserDriver.h: 複数回呼んでよい）")
    XCTAssertTrue(driver.hasRetryTermination)
  }

  /// アプリが既に終了しているときの再送ハンドラは呼んではならないため保持しない。
  func testRetryTerminationNotHeldWhenApplicationTerminated() {
    let driver = UpdateUserDriver(state: makeState())
    driver.showInstallingUpdate(
      withApplicationTerminated: true, retryTerminatingApplication: { XCTFail("呼んではならない") })

    XCTAssertFalse(driver.hasRetryTermination)
    driver.retryTermination()
  }

  /// 再送ハンドラはセッション限り。セッション終了後は死んだハンドラを呼ばない。
  func testRetryTerminationDroppedOnSessionTeardown() {
    let driver = UpdateUserDriver(state: makeState())
    driver.showInstallingUpdate(
      withApplicationTerminated: false, retryTerminatingApplication: { XCTFail("セッション終了後に呼ばない") })

    driver.dismissUpdateInstallation()
    XCTAssertFalse(driver.hasRetryTermination)
    driver.retryTermination()
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

  /// 「今すぐ再起動」の着地先。押下がどこにも着地しない組み合わせが無いこと、とくに
  /// **セッション進行中は `resumeCheck` へ行かず `hold` する**ことを固定する——ここで
  /// `installRequested` 相当の要求を立てて放置すると、そのセッションが更新を提示せず終わった場合に
  /// 要求が残り、次の定期確認（数時間後）で頼んでいない再起動を引き起こす。
  func testRestartLandingHoldsInsteadOfLeavingRequestBehind() {
    typealias Landing = UpdaterService.RestartLanding

    // 進行中で手元に経路が無ければ預かる（新しいセッションは起こせない）。
    XCTAssertEqual(
      Landing.resolve(
        hasRetryTermination: false, hasImmediateInstall: false, hasPendingInstallReply: false,
        availability: .busy), .hold)
    // 空いていれば自分でセッションを起こす。
    XCTAssertEqual(
      Landing.resolve(
        hasRetryTermination: false, hasImmediateInstall: false, hasPendingInstallReply: false,
        availability: .available), .resumeCheck)
    // 保留 reply は進行中でもその場で着地する。
    XCTAssertEqual(
      Landing.resolve(
        hasRetryTermination: false, hasImmediateInstall: false, hasPendingInstallReply: true,
        availability: .busy), .pendingInstallReply)
    // 終了要求の再送が最優先（可否にも他経路にも依らない）。
    XCTAssertEqual(
      Landing.resolve(
        hasRetryTermination: true, hasImmediateInstall: true, hasPendingInstallReply: true,
        availability: .busy), .retryTermination)
    // 次いで即時適用ハンドラ。
    XCTAssertEqual(
      Landing.resolve(
        hasRetryTermination: false, hasImmediateInstall: true, hasPendingInstallReply: true,
        availability: .unavailable), .immediateInstall)
    // updater が動いていなければ何もしない（この状態では再起動ボタンが出ない）。
    XCTAssertEqual(
      Landing.resolve(
        hasRetryTermination: false, hasImmediateInstall: false, hasPendingInstallReply: false,
        availability: .unavailable), .inactive)
  }

  /// サイレント経路は YES を返すとセッションが生きたまま残る＝`canCheckForUpdates` が真へ戻らないため、
  /// KVO 側の消化が来ない。預かっていた「今すぐ再起動」はこの瞬間に消化される。
  func testWillInstallUpdateOnQuitDrainsHeldRestartPress() {
    let service = UpdaterService()
    service.pendingRestart = true

    let installed = expectation(description: "預かった押下が即時適用へ着地する")
    _ = service.updater(
      SPUUpdater(
        hostBundle: .main, applicationBundle: .main,
        userDriver: UpdateUserDriver(state: makeState()), delegate: nil),
      willInstallUpdateOnQuit: SUAppcastItem.empty(),
      immediateInstallationBlock: { installed.fulfill() })

    wait(for: [installed], timeout: 1)
    XCTAssertFalse(service.pendingRestart, "消化した押下は残さない")
    XCTAssertFalse(service.driver.installRequested, "セッションを越えて残る要求を立てない")
  }

  /// 預かった押下の主経路: 確認できるようになった瞬間（`canCheckForUpdates` の KVO）に
  /// 自分で撃ち直して着地させる。着地の観測点には終了要求の再送を使う——可否に依らず
  /// 最優先で選ばれるので、消化が起きたことだけを決定論的に見られる。
  func testAvailabilityChangeDrainsHeldRestartPress() {
    let service = UpdaterService()
    var retried = 0
    service.driver.showInstallingUpdate(
      withApplicationTerminated: false, retryTerminatingApplication: { retried += 1 })
    service.pendingRestart = true

    XCTAssertEqual(retried, 0, "可否が変わるまでは撃たない")

    service.updaterAvailabilityDidChange()

    XCTAssertEqual(retried, 1, "預かった押下は可否の変化で消化されて着地する")
    XCTAssertFalse(service.pendingRestart, "消化した押下は残さない")
  }

  /// 押下を預かっていないときは、確認できるようになっただけでは何も起きない
  /// （頼んでいないタイミングでアプリを終了させない）。
  func testAvailabilityChangeDoesNotRestartWithoutPress() {
    let service = UpdaterService()
    service.driver.showInstallingUpdate(
      withApplicationTerminated: false,
      retryTerminatingApplication: { XCTFail("押していないのに終了要求を送ってはならない") })

    service.updaterAvailabilityDidChange()

    XCTAssertFalse(service.pendingRestart)
  }

  /// 同じ受け口が可否の写像も行う。ここが写さないと UI が古い可否のまま固まる
  /// （＝実行できない状態を名乗り続ける）。
  func testAvailabilityChangeMirrorsAvailabilityToState() {
    let service = UpdaterService()
    service.state.setCheckAvailability(.available)  // 古い値で固まっている状況を作る

    service.updaterAvailabilityDidChange()

    XCTAssertEqual(
      service.state.checkAvailability, .unavailable, "起動ゲートを通っていない現在値を写す")
  }

  /// 押下を預かっていないときは、サイレント staged が届いても勝手に再起動しない
  /// （頼んでいないタイミングでアプリを終了させない）。
  func testWillInstallUpdateOnQuitDoesNotRestartWithoutPress() {
    let service = UpdaterService()
    _ = service.updater(
      SPUUpdater(
        hostBundle: .main, applicationBundle: .main,
        userDriver: UpdateUserDriver(state: makeState()), delegate: nil),
      willInstallUpdateOnQuit: SUAppcastItem.empty(),
      immediateInstallationBlock: { XCTFail("押していないのに再起動してはならない") })

    let settled = expectation(description: "drain の async turn を通す")
    DispatchQueue.main.async { settled.fulfill() }
    wait(for: [settled], timeout: 1)
  }

  /// updater が起動していないビルド（`SUFeedURL` の無いテスト/dev バイナリ）は「進行中」ではなく
  /// 「不活性」を名乗る。両者を同じ false へ潰すと、確認が走っていないのに UI が
  /// 「アップデートを確認中…」と嘘をつく。
  func testUnstartedServiceReportsUnavailableNotBusy() {
    let service = UpdaterService()
    service.startIfPermitted()  // テストバンドルには SUFeedURL が無くゲートで弾かれる

    XCTAssertFalse(service.started, "テストバンドルには SUFeedURL が無く起動ゲートを通らない")
    XCTAssertEqual(service.state.checkAvailability, .unavailable)
    XCTAssertFalse(service.state.canCheckNow)
    XCTAssertEqual(
      UpdateCheckNowAppearance.resolve(service.state), .dimmed,
      "確認は走っていないので「確認中…」を名乗らない")
  }
}
