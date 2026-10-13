import AppKit
import XCTest

@testable import Orbe

/// 通知先が通知センターの自動化。許可があれば名前と結果の 1 行を自動化ごとの識別子で通知センターへ出し、ピルは出さない。
/// 許可が無い・未確認・出せなかった回はピルに出し、未確認なら許可を求める。音はどの面でも鳴る。定義を通知センターへ書き換えた
/// 直後に（AI の口でもボードでも）許可を求め、消したら取り下げる。通知のクリックはピルと同じ行き先。
///
/// 壊れると何が起きるか: 許可を切った人や答えていない人に知らせがどこにも届かない。通知センターに同じ自動化の通知が溜まる。
/// 消した自動化の通知が残り、押すと欄に落ちる。AI に頼んだ・ボードで選んだその場で許可の問いが出ず、初めての
/// 回まで気づけない。
extension WindowControllerAutomationNoticeTests {
  @MainActor private func notifier(_ wc: WindowController) throws -> SystemNotifierFake {
    try XCTUnwrap(wc.systemNotifier as? SystemNotifierFake, "隔離ハーネスが通知センターをフェイクへ差していない")
  }

  @MainActor func testAnAuthorizedRunGoesToNotificationCenterWithTheSound() throws {
    let wc = controller()
    let center = try notifier(wc)
    center.authorization = .authorized
    let sound = try XCTUnwrap(wc.soundPlayer as? SoundPlayerFake)
    let id = try recorded(wc, notify: .notificationCenter)

    wc.notifyAutomationRecorded(id)

    XCTAssertEqual(
      center.posted,
      [
        SystemNotificationContent(
          identifier: "automation.\(id)", title: "開いている PR の要約", body: "PR は 3 件",
          automationId: id)
      ])
    XCTAssertNil(wc.attentionStore.transient, "通知センターに出た回はピルを出さない")
    XCTAssertEqual(sound.played.map(\.event), [.done])
  }

  /// 未確認なら許可を求めてピルへ、拒否ならピルだけ、出せなかった回もピル。どれも音は鳴る。
  @MainActor func testWithoutPermissionTheRunStandsAsAPill() throws {
    let wc = controller()
    let center = try notifier(wc)
    let sound = try XCTUnwrap(wc.soundPlayer as? SoundPlayerFake)

    let undetermined = try recorded(wc, notify: .notificationCenter)
    wc.notifyAutomationRecorded(undetermined)
    XCTAssertEqual(standing(wc)?.automationId, undetermined)
    XCTAssertEqual(center.requestCount, 1)

    center.authorization = .denied
    let denied = try recorded(wc, name: "拒否", notify: .notificationCenter)
    wc.notifyAutomationRecorded(denied)
    XCTAssertEqual(standing(wc)?.automationId, denied)

    center.authorization = .authorized
    center.postSucceeds = false
    let failed = try recorded(wc, name: "出せない", notify: .notificationCenter)
    wc.notifyAutomationRecorded(failed)
    XCTAssertEqual(standing(wc)?.automationId, failed)

    XCTAssertTrue(center.posted.isEmpty)
    XCTAssertEqual(center.requestCount, 1)
    XCTAssertEqual(sound.played.count, 3)
  }

  @MainActor func testAMenuBarRunNeverTouchesNotificationCenter() throws {
    let wc = controller()
    let center = try notifier(wc)
    center.authorization = .authorized

    wc.notifyAutomationRecorded(try recorded(wc, notify: .menuBar))

    XCTAssertNotNil(standing(wc))
    XCTAssertTrue(center.posted.isEmpty)
  }

  /// 通知センターへの書き換えはその場で許可を求め、メニューバーへの書き換えは求めない。ボードの ⌘⌫ で消しても、その自動化の
  /// 通知を取り下げる（取り下げが制御 API の削除だけに付いていると、人の手で消した自動化の通知が残る）。
  @MainActor func testSettingAsksForPermissionAndDeletingFromTheBoardWithdraws() throws {
    let wc = controller()
    let center = try notifier(wc)
    var definition = AutomationStoreTests.definition()
    definition.notify = .menuBar
    guard
      case .success(let created) = wc.controlSetAutomation(automationId: nil, definition),
      let id = ((created as? [String: Any])?["automation"] as? [String: Any])?["automationId"]
        as? Int
    else { return XCTFail("作れない") }
    XCTAssertEqual(center.requestCount, 0)

    definition.notify = .notificationCenter
    _ = wc.controlSetAutomation(automationId: id, definition)
    XCTAssertEqual(center.requestCount, 1)

    wc.showAutomation(id)
    wc.board.automation.perform(.delete)
    XCTAssertNil(wc.automationStore.automation(id), "前提: ボードの ⌘⌫ で消えていない")
    XCTAssertEqual(center.removed, ["automation.\(id)"])
  }

  /// ボードのサブメニューで通知センターを選んでも、AI の口と同じくその場で許可を求める。
  @MainActor func testChoosingNotificationCenterOnTheBoardAsksForPermission() throws {
    let wc = controller()
    let center = try notifier(wc)
    let id = try wc.automationStore.create(AutomationStoreTests.definition(), now: Date()).id
    wc.showAutomation(id)

    wc.board.automation.openNotify()
    wc.board.automation.chooseNotify(.notificationCenter)

    XCTAssertEqual(wc.automationStore.automation(id)?.definition.notify, .notificationCenter)
    XCTAssertEqual(center.requestCount, 1)
  }

  @MainActor func testClickingTheNotificationOpensTheAutomationOnTheBoard() throws {
    let wc = controller()
    let id = try recorded(wc, notify: .notificationCenter)
    wc.showTaskPalette()

    try notifier(wc).onOpenAutomation?(id)

    XCTAssertEqual(wc.presentedOverlay, AppShellModel.Overlay.none)
    XCTAssertEqual(wc.current.selection, .board)
    XCTAssertEqual(wc.board.automation.list.selectedID, .automation(id))
  }
}
