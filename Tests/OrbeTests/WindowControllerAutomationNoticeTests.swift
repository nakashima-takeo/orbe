import AppKit
import OrbeSound
import XCTest

@testable import Orbe

/// 自動化の知らせ。通知をメニューバーにした自動化が出した回・失敗した回を記録すると、名前と結果の 1 行のピルが Home の設定で
/// 立ち、出した回は完了の音・失敗は入力待ちの音が鳴る。off・何も出さなかった回・その行を見ているときは出ない。ピルのクリックは
/// Home のボードでその自動化の行を選び、焦点を一覧へ置く。
///
/// 壊れると何が起きるか: 通知を付けていない自動化や、新着の無い 10 分ごとの回でピルが出続ける。見ている行の回でも鳴る。
/// ピルを押してもボードの欄が選ばれ、どの自動化の知らせだったかを探し直すことになる。
///
/// 重要: 実 NSWindow に WindowController を接続するため **libghostty ランタイムを起動する**（GhosttyKit 必須）。
final class WindowControllerAutomationNoticeTests: OrbeTestCase {
  private var shown: WindowController?

  override func setUp() {
    super.setUp()
    AppStatePersistence.save(AppStateFile(preferredLanguage: "ja"))
  }

  override func tearDown() {
    shown?.window.orderOut(nil)
    shown = nil
    super.tearDown()
  }

  @MainActor private func controller() -> WindowController {
    AutomationPersistence.save(DesignSceneFixtures.automationEmptyFile())
    let wc = WindowController()
    shown = wc
    wc.dismissPalette()
    return wc
  }

  @MainActor private func key(_ wc: WindowController) {
    NSApplication.shared.setActivationPolicy(.accessory)
    wc.window.makeKeyAndOrderFront(nil)
    NSApplication.shared.activate(ignoringOtherApps: true)
    let end = Date().addingTimeInterval(2)
    while !wc.window.isKeyWindow, Date() < end {
      guard
        let event = NSApp.nextEvent(
          matching: .any, until: Date().addingTimeInterval(0.01), inMode: .default, dequeue: true)
      else { continue }
      NSApp.sendEvent(event)
    }
    XCTAssertTrue(wc.window.isKeyWindow, "前提: ウィンドウが key にならない環境ではこの契約を測れない")
  }

  /// 通知 `notify` の報告の自動化を作り、`report` の回（`failure` なら失敗の回）を記録する。
  @MainActor private func recorded(
    _ wc: WindowController, notify: AutomationNotify? = .menuBar,
    report: String? = "PR は 3 件\n- #1",
    failure: String? = nil
  ) throws -> Int {
    var definition = AutomationStoreTests.definition("開いている PR の要約")
    definition.sink = .report
    definition.notify = notify
    let automation = try wc.automationStore.create(definition, now: Date())
    let run = AutomationRun(
      startedAt: Date(), endedAt: Date(), trigger: .now, source: nil, fresh: nil, steps: [],
      sink: nil, failure: failure)
    if failure != nil {
      wc.automationStore.recordFailure(of: automation.id, run)
    } else {
      wc.automationStore.commit(automation.id, run, fetched: []) { _, _ in .report(text: report) }
    }
    return automation.id
  }

  @MainActor func testAReportStandsWithTheHomeSettingsAndTheDoneSound() throws {
    let wc = controller()
    let sound = try XCTUnwrap(wc.soundPlayer as? SoundPlayerFake)
    let home = wc.workspaces[try XCTUnwrap(wc.store.homeIndex)]
    var override = SettingsLayer()
    override[SettingKeys.notificationSound] = .preset(.steel)
    override[SettingKeys.menuBarNotificationDuration] = 40
    home.settingsOverride = override
    let id = try recorded(wc)

    wc.notifyAutomationRecorded(id)

    let transient = try XCTUnwrap(wc.attentionStore.transient)
    guard case .automation(let notice) = transient.notice else { return XCTFail("\(transient)") }
    XCTAssertEqual(
      notice,
      AutomationNotice(automationId: id, name: "開いている PR の要約", text: "PR は 3 件", failed: false))
    XCTAssertEqual(transient.expiresAt.timeIntervalSince(transient.arrivedAt), 40, accuracy: 0.001)
    XCTAssertEqual(sound.played.map(\.event), [.done])
  }

  @MainActor func testAFailureStandsWithTheWaitingSound() throws {
    let wc = controller()
    let sound = try XCTUnwrap(wc.soundPlayer as? SoundPlayerFake)
    let id = try recorded(wc, failure: "the fetch ended: exited 1: boom")

    wc.notifyAutomationRecorded(id)

    guard case .automation(let notice) = wc.attentionStore.transient?.notice else {
      return XCTFail("ピルが立たない")
    }
    XCTAssertTrue(notice.failed)
    XCTAssertEqual(notice.text, "失敗：the fetch ended: exited 1: boom")
    XCTAssertEqual(sound.played.map(\.event), [.waiting])
  }

  @MainActor func testOffOrNothingDeliveredStaysSilent() throws {
    let wc = controller()
    let sound = try XCTUnwrap(wc.soundPlayer as? SoundPlayerFake)
    wc.notifyAutomationRecorded(try recorded(wc, notify: nil))
    wc.notifyAutomationRecorded(try recorded(wc, report: nil))
    XCTAssertNil(wc.attentionStore.transient)
    XCTAssertTrue(sound.played.isEmpty)
  }

  @MainActor func testViewingTheRowStaysSilent() throws {
    let wc = controller()
    key(wc)
    let sound = try XCTUnwrap(wc.soundPlayer as? SoundPlayerFake)
    let id = try recorded(wc)
    wc.showAutomation(id)
    XCTAssertTrue(wc.isViewingAutomation(id))

    wc.notifyAutomationRecorded(id)

    XCTAssertNil(wc.attentionStore.transient)
    XCTAssertTrue(sound.played.isEmpty)
  }

  /// ピルのクリックは、開いているパレットを閉じ、Home のボードでその自動化の行を選んで一覧に焦点を置く。消えた自動化なら欄。
  @MainActor func testThePillOpensTheAutomationOnTheBoard() throws {
    let wc = controller()
    key(wc)
    let id = try recorded(wc)
    wc.showTaskPalette()

    wc.showAutomation(id)

    XCTAssertEqual(wc.presentedOverlay, AppShellModel.Overlay.none)
    XCTAssertTrue(wc.store.isHome(wc.activeWorkspace))
    XCTAssertEqual(wc.current.selection, .board)
    XCTAssertEqual(wc.board.automation.list.selectedID, .automation(id))
    XCTAssertEqual(wc.board.automation.place, .list)

    try wc.automationRunner.delete(id)
    wc.showAutomation(id)
    XCTAssertEqual(wc.board.automation.list.selectedID, .request)
  }

  @MainActor func testThePillKeepsAModalOverlay() throws {
    let wc = controller()
    let id = try recorded(wc)
    wc.model.overlay = .onboarding
    wc.showAutomation(id)
    XCTAssertEqual(wc.presentedOverlay, .onboarding)
    XCTAssertNotEqual(wc.board.automation.list.selectedID, .automation(id))
  }
}
