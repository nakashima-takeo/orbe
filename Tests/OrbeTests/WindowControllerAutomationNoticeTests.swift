import AppKit
import OrbeSound
import XCTest

@testable import Orbe

/// 自動化の知らせ。通知をメニューバーにした自動化の部品が出した回・失敗した回を記録すると、名前と「部品: 結果」の 1 行のピルが
/// Home の設定で立ち、出した回は完了の音・失敗は入力待ちの音が鳴る。失敗は部品ごとに続く間の最初の回だけ。off・何も出さなかった回・その行を見ている
/// ときは出ない。ピルのクリックは Home のボードでその自動化の行を選び、焦点を一覧へ置く。
///
/// 壊れると何が起きるか: 通知を付けていない自動化や、新着の無い 10 分ごとの回でピルが出続ける。認証切れで失敗し続ける自動化が
/// 回ごとに鳴る。見ている行の回でも鳴る。Home のボードを開いているだけで、ほかの自動化の知らせが消える。ピルを押してもボードの
/// 欄が選ばれ、どの自動化の知らせだったかを探し直すことになる。
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

  @MainActor func controller() -> WindowController {
    let wc = WindowController()
    shown = wc
    wc.dismissPalette()
    return wc
  }

  @MainActor func key(_ wc: WindowController) {
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

  /// 入力の無い報告の部品 `digest`（名前「要約」）だけの自動化。
  static func reportDefinition(
    _ name: String = "開いている PR の要約", notify: AutomationNotify? = .menuBar
  ) -> AutomationDefinition {
    AutomationDefinition(
      name: name, notify: notify,
      parts: [
        DesignSceneFixtures.agentPart(
          "digest", "要約", .scheduled(.every(1440)), instruction: "PR を要約する", deliver: .report)
      ])
  }

  /// 通知 `notify` の報告の自動化を作り、`report` の回（`failure` なら失敗の回）を記録する。
  @MainActor func recorded(
    _ wc: WindowController, name: String = "開いている PR の要約",
    notify: AutomationNotify? = .menuBar, report: String? = "PR は 3 件\n- #1",
    failure: String? = nil
  ) throws -> Int {
    let automation = try wc.automationStore.create(
      Self.reportDefinition(name, notify: notify), now: Date())
    try record(wc, automation.id, report: report, failure: failure)
    return automation.id
  }

  /// `id` の自動化に `report` の回（`failure` なら失敗の回）を記録する。
  @MainActor func record(
    _ wc: WindowController, _ id: Int, report: String? = "PR は 3 件\n- #1",
    failure: String? = nil
  ) throws {
    _ = try wc.automationStore.record(
      AutomationPassEnd(
        automationId: id, part: "digest", trigger: .now, startedAt: Date(), endedAt: Date(),
        take: nil,
        outcome: failure.map { DesignSceneFixtures.failed($0) }
          ?? DesignSceneFixtures.reported(report)))
  }

  @MainActor func standing(_ wc: WindowController) -> AutomationNotice? {
    guard case .automation(let notice) = wc.attentionStore.transient?.notice else { return nil }
    return notice
  }

  @MainActor func testAReportStandsWithTheHomeSettingsAndTheDoneSound() throws {
    let wc = controller()
    let sound = try XCTUnwrap(wc.soundPlayer as? SoundPlayerFake)
    let home = wc.workspaces[try XCTUnwrap(wc.store.homeIndex)]
    var override = SettingsLayer()
    override[SettingKeys.notificationSound] = .preset(.steel)
    override[SettingKeys.notificationSoundVolume] = 30
    override[SettingKeys.menuBarNotificationDuration] = 40
    home.settingsOverride = override
    let id = try recorded(wc)

    wc.notifyAutomationRecorded(id, "digest")

    let transient = try XCTUnwrap(wc.attentionStore.transient)
    guard case .automation(let notice) = transient.notice else { return XCTFail("\(transient)") }
    XCTAssertEqual(
      notice,
      AutomationNotice(
        automationId: id, name: "開いている PR の要約", text: "要約: PR は 3 件", failed: false))
    XCTAssertEqual(transient.expiresAt.timeIntervalSince(transient.arrivedAt), 40, accuracy: 0.001)
    XCTAssertEqual(sound.played, [.synth(.steel, event: .done, volume: 30)])
  }

  @MainActor func testAFailureStandsWithTheWaitingSound() throws {
    let wc = controller()
    let sound = try XCTUnwrap(wc.soundPlayer as? SoundPlayerFake)
    let id = try recorded(wc, failure: "the part \"digest\" ended: exited 1: boom")

    wc.notifyAutomationRecorded(id, "digest")

    guard case .automation(let notice) = wc.attentionStore.transient?.notice else {
      return XCTFail("ピルが立たない")
    }
    XCTAssertTrue(notice.failed)
    XCTAssertEqual(notice.text, "要約: 失敗：the part \"digest\" ended: exited 1: boom")
    XCTAssertEqual(sound.played.map(\.event), [.waiting])
  }

  /// 失敗が続く間は最初の失敗だけを知らせ、成功（何も出さない回も）を挟んだ失敗はまた知らせる。
  @MainActor func testOnlyTheFirstOfConsecutiveFailuresStands() throws {
    let wc = controller()
    let sound = try XCTUnwrap(wc.soundPlayer as? SoundPlayerFake)
    let id = try recorded(wc, failure: "the part \"digest\" ended: exited 1: boom")
    wc.notifyAutomationRecorded(id, "digest")
    XCTAssertEqual(standing(wc)?.failed, true)

    try record(wc, id, failure: "the part \"digest\" ended: exited 1: boom")
    XCTAssertNil(wc.automationNotification(id, "digest"), "続く失敗は知らせない")
    wc.notifyAutomationRecorded(id, "digest")
    XCTAssertEqual(sound.played.map(\.event), [.waiting])

    try record(wc, id, report: nil)
    wc.notifyAutomationRecorded(id, "digest")
    try record(wc, id, failure: "the part \"digest\" ended: exited 1: boom")
    XCTAssertNotNil(wc.automationNotification(id, "digest"), "何も出さない回を挟んだ失敗は知らせる")
    wc.notifyAutomationRecorded(id, "digest")
    XCTAssertEqual(sound.played.map(\.event), [.waiting, .waiting])
  }

  @MainActor func testOffOrNothingDeliveredStaysSilent() throws {
    let wc = controller()
    let sound = try XCTUnwrap(wc.soundPlayer as? SoundPlayerFake)
    wc.notifyAutomationRecorded(try recorded(wc, notify: nil), "digest")
    wc.notifyAutomationRecorded(try recorded(wc, report: nil), "digest")
    XCTAssertNil(wc.attentionStore.transient)
    XCTAssertTrue(sound.played.isEmpty)
  }

  /// 選んでいる行の回は出ず、同じボードで選んでいない自動化の回は出る。
  @MainActor func testViewingTheRowStaysSilent() throws {
    let wc = controller()
    key(wc)
    let sound = try XCTUnwrap(wc.soundPlayer as? SoundPlayerFake)
    let id = try recorded(wc)
    let other = try recorded(wc, name: "GitHub: レビュー依頼")
    wc.showAutomation(id)
    XCTAssertTrue(wc.isViewingAutomation(id))

    wc.notifyAutomationRecorded(id, "digest")
    XCTAssertNil(wc.attentionStore.transient)
    XCTAssertTrue(sound.played.isEmpty)

    wc.notifyAutomationRecorded(other, "digest")
    XCTAssertEqual(standing(wc)?.automationId, other)
    XCTAssertEqual(sound.played.count, 1)
  }

  /// Orbe が背面なら、ボードでその行を選んだまま残っていても誰も見ていないので出る。
  @MainActor func testTheSelectedRowStandsWhileOrbeIsInBackground() throws {
    let wc = controller()
    let sound = try XCTUnwrap(wc.soundPlayer as? SoundPlayerFake)
    let id = try recorded(wc)
    wc.showAutomation(id)
    XCTAssertFalse(wc.window.isKeyWindow, "前提: Orbe は背面")

    wc.notifyAutomationRecorded(id, "digest")

    XCTAssertEqual(standing(wc)?.automationId, id)
    XCTAssertEqual(sound.played.count, 1)
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
