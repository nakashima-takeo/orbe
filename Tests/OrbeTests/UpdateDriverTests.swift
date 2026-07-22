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
}
